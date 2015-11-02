(*
 * Copyright (C) 2015 David Scott <dave@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)
open Sexplib.Std
open Result
open Error
open Offset
open Types

let ( <| ) = Int64.shift_left
let ( |> ) = Int64.shift_right_logical

module Make(B: S.RESIZABLE_BLOCK) = struct

  type 'a io = 'a Lwt.t
  type error = B.error
  type info = {
    read_write : bool;
    sector_size : int;
    size_sectors : int64;
  }

  type id = B.id
  type page_aligned_buffer = B.page_aligned_buffer
  type t = {
    h: Header.t;
    base: B.t;
    base_info: B.info;
    info: info;
    mutable next_cluster: int64;
    (* for convenience *)
    cluster_bits: int;
    sector_size: int;
  }

  let get_info t = Lwt.return t.info

  let (>>*=) m f =
    let open Lwt in
    m >>= function
    | `Error x -> Lwt.return (`Error x)
    | `Ok x -> f x

  let rec iter f = function
    | [] -> Lwt.return (`Ok ())
    | x :: xs ->
        f x >>*= fun () ->
        iter f xs

  (* Mmarshal a disk offset written at a given offset within the disk. *)
  let marshal_offset t offset v =
    let sector, within = to_sector ~sector_size:t.sector_size offset in
    let buf = Cstruct.sub Io_page.(to_cstruct (get 1)) 0 t.base_info.B.sector_size in
    B.read t.base sector [ buf ]
    >>*= fun () ->
    match Offset.write v (Cstruct.shift buf within) with
    | Error (`Msg m) -> Lwt.return (`Error (`Unknown m))
    | Ok _ -> B.write t.base sector [ buf ]

  (* Unmarshal a disk offset written at a given offset within the disk. *)
  let unmarshal_offset t offset =
    let sector, within = to_sector ~sector_size:t.sector_size offset in
    let buf = Cstruct.sub Io_page.(to_cstruct (get 1)) 0 t.base_info.B.sector_size in
    B.read t.base sector [ buf ]
    >>*= fun () ->
    let buf = Cstruct.shift buf within in
    match Offset.read buf with
    | Error (`Msg m) -> Lwt.return (`Error (`Unknown m))
    | Ok x -> Lwt.return (`Ok x)

  let resize t new_size =
    let sector, within = Offset.to_sector ~sector_size:t.sector_size new_size in
    if within <> 0
    then Lwt.return (`Error (`Unknown (Printf.sprintf "Internal error: attempting to resize to a non-sector multiple %s" (Offset.to_string new_size))))
    else B.resize t.base sector

  module Cluster = struct

    let malloc t =
      let cluster_bits = Int32.to_int t.Header.cluster_bits in
      let npages = max 1 (cluster_bits lsl (cluster_bits - 12)) in
      let pages = Io_page.(to_cstruct (get npages)) in
      Cstruct.sub pages 0 (1 lsl cluster_bits)

    (** Allocate a cluster, resize the underlying device and return the
        byte offset of the new cluster, suitable for writing to one of
        the various metadata tables. *)
    let extend t =
      let cluster = t.next_cluster in
      t.next_cluster <- Int64.succ t.next_cluster;
      resize t (Offset.make (t.next_cluster <| t.cluster_bits))
      >>*= fun () ->
      Lwt.return (`Ok (Offset.make (cluster <| t.cluster_bits)))

    (** Increment the refcount of a given cluster. Note this might need
        to allocate itself, to enlarge the refcount table. *)
    let incr_refcount t cluster =
      let cluster_bits = Int32.to_int t.h.Header.cluster_bits in
      let size = t.h.Header.size in
      let cluster_size = 1L <| cluster_bits in
      let index_in_cluster = Int64.(to_int (div cluster (Header.refcounts_per_cluster t.h))) in
      let within_cluster = Int64.(to_int (rem cluster (Header.refcounts_per_cluster t.h))) in
      if index_in_cluster > 0
      then Lwt.return (`Error (`Unknown "I don't know how to enlarge a refcount table yet"))
      else begin
        let cluster = malloc t.h in
        let refcount_table_sector = Int64.(div t.h.Header.refcount_table_offset (of_int t.base_info.B.sector_size)) in
        B.read t.base refcount_table_sector [ cluster ]
        >>*= fun () ->
        ( match Offset.read (Cstruct.shift cluster (8 * index_in_cluster)) with
          | Ok (offset, _) -> Lwt.return (`Ok offset)
          | Error (`Msg m) -> Lwt.return (`Error (`Unknown m)) )
        >>*= fun offset ->
        if Offset.to_bytes offset = 0L then begin
          extend t
          >>*= fun offset ->
          let cluster' = malloc t.h in
          Cstruct.memset cluster' 0;
          Cstruct.BE.set_uint16 cluster' (2 * within_cluster) 1;
          let sector, _ = Offset.to_sector ~sector_size:t.sector_size offset in
          B.write t.base sector [ cluster' ]
          >>*= fun () ->
          ( match Offset.write offset (Cstruct.shift cluster (8 * index_in_cluster)) with
            | Ok _ -> Lwt.return (`Ok ())
            | Error (`Msg m) -> Lwt.return (`Error (`Unknown m)) )
          >>*= fun () ->
          B.write t.base refcount_table_sector [ cluster ]
          >>*= fun () ->
          (* recursively increment refcunt of offset? *)
          Lwt.return (`Ok ())
        end else begin
          let sector, _ = to_sector ~sector_size:t.sector_size offset in
          B.read t.base sector [ cluster ]
          >>*= fun () ->
          let count = Cstruct.BE.get_uint16 cluster (2 * within_cluster) in
          Cstruct.BE.set_uint16 cluster (2 * within_cluster) (count + 1);
          B.write t.base sector [ cluster ]
        end
      end

    (* Walk the L1 and L2 tables to translate an address *)
    let walk ?(allocate=false) t a =
      let table_offset = t.h.Header.l1_table_offset in
      (* Read l1[l1_index] as a 64-bit offset *)
      let l1_table_start = Offset.make t.h.Header.l1_table_offset in
      let l1_index_offset = Offset.shift l1_table_start (Int64.mul 8L a.Virtual.l1_index) in
      unmarshal_offset t l1_index_offset
      >>*= fun (l2_table_offset, _) ->

      let (>>|=) m f =
        let open Lwt in
        m >>= function
        | `Error x -> Lwt.return (`Error x)
        | `Ok None -> Lwt.return (`Ok None)
        | `Ok (Some x) -> f x in

      (* Look up an L2 table *)
      ( if Offset.to_bytes l2_table_offset = 0L then begin
          if not allocate then begin
            Lwt.return (`Ok None)
          end else begin
            extend t
            >>*= fun offset ->
            let cluster, _ = Offset.to_cluster ~cluster_bits:t.cluster_bits offset in
            incr_refcount t cluster
            >>*= fun () ->
            marshal_offset t l1_index_offset offset
            >>*= fun () ->
            Lwt.return (`Ok (Some offset))
          end
        end else begin
          if Offset.is_compressed l2_table_offset then failwith "compressed";
          Lwt.return (`Ok (Some l2_table_offset))
        end
      ) >>|= fun l2_table_offset ->

      (* Look up a cluster *)
      let l2_index_offset = Offset.shift l2_table_offset (Int64.mul 8L a.Virtual.l2_index) in
      unmarshal_offset t l2_index_offset
      >>*= fun (cluster_offset, _) ->
      ( if Offset.to_bytes cluster_offset = 0L then begin
          if not allocate then begin
            Lwt.return (`Ok None)
          end else begin
            extend t
            >>*= fun offset ->
            let cluster, _ = Offset.to_cluster ~cluster_bits:t.cluster_bits offset in
            incr_refcount t cluster
            >>*= fun () ->
            marshal_offset t l2_index_offset offset
            >>*= fun () ->
            Lwt.return (`Ok (Some offset))
          end
        end else begin
          if Offset.is_compressed cluster_offset then failwith "compressed";
          Lwt.return (`Ok (Some cluster_offset))
        end
      ) >>|= fun cluster_offset ->

      if Offset.to_bytes cluster_offset = 0L
      then Lwt.return (`Ok None)
      else Lwt.return (`Ok (Some (Offset.shift cluster_offset a.Virtual.cluster)))

  end

  (* Decompose into single sector reads *)
  let rec chop into ofs = function
    | [] -> []
    | buf :: bufs ->
      if Cstruct.len buf > into then begin
        let this = ofs, Cstruct.sub buf 0 into in
        let rest = chop into (Int64.succ ofs) (Cstruct.shift buf into :: bufs) in
        this :: rest
      end else begin
        (ofs, buf) :: (chop into (Int64.succ ofs) bufs)
      end

  let read t sector bufs =
    (* Inefficiently perform 3x physical I/Os for every 1 virtual I/O *)
    iter (fun (sector, buf) ->
      let byte = Int64.mul sector 512L in
      let vaddr = Virtual.make ~cluster_bits:t.cluster_bits byte in
      Cluster.walk t vaddr
      >>*= function
      | None ->
        Cstruct.memset buf 0;
        Lwt.return (`Ok ())
      | Some offset' ->
        let base_sector, _ = Offset.to_sector ~sector_size:t.sector_size offset' in
        B.read t.base base_sector [ buf ]
    ) (chop t.base_info.B.sector_size sector bufs)

  let write t sector bufs =
    (* Inefficiently perform 3x physical I/Os for every 1 virtual I/O *)
    iter (fun (sector, buf) ->
      let byte = Int64.mul sector 512L in
      let vaddr = Virtual.make ~cluster_bits:t.cluster_bits byte in
      Cluster.walk ~allocate:true t vaddr
      >>*= function
      | None ->
        Lwt.return (`Error (`Unknown "this should never happen"))
      | Some offset' ->
        let base_sector, _ = Offset.to_sector ~sector_size:t.sector_size offset' in
        B.write t.base base_sector [ buf ]
    ) (chop t.base_info.B.sector_size sector bufs)

  let disconnect t = B.disconnect t.base

  let make base h =
    let open Lwt in
    B.get_info base
    >>= fun base_info ->
    (* The virtual disk has 512 byte sectors *)
    let info' = {
      read_write = false;
      sector_size = 512;
      size_sectors = Int64.(div h.Header.size 512L);
    } in
    (* We assume the backing device is resized dynamically so the
       size is the address of the next cluster *)
    let sector_size = base_info.B.sector_size in
    let cluster_bits = Int32.to_int h.Header.cluster_bits in
    let size_bytes = Int64.(mul base_info.B.size_sectors (of_int sector_size)) in
    let next_cluster = Int64.(div size_bytes (1L <| cluster_bits)) in
    Lwt.return (`Ok { h; base; info = info'; base_info; next_cluster; sector_size; cluster_bits })

  let connect base =
    let open Lwt in
    B.get_info base
    >>= fun base_info ->
    let sector = Cstruct.sub Io_page.(to_cstruct (get 1)) 0 base_info.B.sector_size in
    B.read base 0L [ sector ]
    >>= function
    | `Error x -> Lwt.return (`Error x)
    | `Ok () ->
      match Header.read sector with
      | Error (`Msg m) -> Lwt.return (`Error (`Unknown m))
      | Ok (h, _) -> make base h

  let create base size =
    let version = `Two in
    let backing_file_offset = 0L in
    let backing_file_size = 0l in
    let cluster_bits = 16 in
    let cluster_size = 1L <| cluster_bits in
    let crypt_method = `None in
    (* qemu-img places the refcount table next in the file and only
       qemu-img creates a tiny refcount table and grows it on demand *)
    let refcount_table_offset = cluster_size in
    let refcount_table_clusters = 1L in

    (* qemu-img places the L1 table after the refcount table *)
    let l1_table_offset = Int64.(mul (add 1L refcount_table_clusters) (1L <| cluster_bits)) in
    (* The L2 table is of size (1L <| cluster_bits) bytes
       and contains (1L <| (cluster_bits - 3)) 8-byte pointers.
       A single L2 table therefore manages
       (1L <| (cluster_bits - 3)) * (1L <| cluster_bits) bytes
       = (1L <| (2 * cluster_bits - 3)) bytes. *)
    let bytes_per_l2 = 1L <| (2 * cluster_bits - 3) in
    let l2_tables_required = Int64.div (Int64.round_up size bytes_per_l2) bytes_per_l2 in
    let nb_snapshots = 0l in
    let snapshots_offset = 0L in
    let h = {
      Header.version; backing_file_offset; backing_file_size;
      cluster_bits = Int32.of_int cluster_bits; size; crypt_method;
      l1_size = Int64.to_int32 l2_tables_required;
      l1_table_offset; refcount_table_offset;
      refcount_table_clusters = Int64.to_int32 refcount_table_clusters;
      nb_snapshots; snapshots_offset
    } in
    (* Resize the underlying device to contain the header + refcount table
       + l1 table. Future allocations will enlarge the file. *)
    let l1_size_bytes = Int64.mul 8L l2_tables_required in
    let next_free_byte = Int64.round_up (Int64.add l1_table_offset l1_size_bytes) cluster_size in
    let open Lwt in
    B.get_info base
    >>= fun base_info ->
    make base h
    >>*= fun t ->
    resize t (Offset.make next_free_byte)
    >>*= fun () ->

    let page = Io_page.(to_cstruct (get 1)) in
    match Header.write h page with
    | Result.Ok _ ->
      B.write base 0L [ page ]
      >>*= fun () ->

      (* Write an initial empty refcount table *)
      let cluster = Cluster.malloc t.h in
      Cstruct.memset cluster 0;
      B.write base Int64.(div refcount_table_offset (of_int t.base_info.B.sector_size)) [ cluster ]
      >>*= fun () ->
      Cluster.incr_refcount t 0L (* header *)
      >>*= fun () ->
      Cluster.incr_refcount t (Int64.div refcount_table_offset cluster_size)
      >>*= fun () ->
      (* Write an initial empty L1 table *)
      B.write base Int64.(div l1_table_offset (of_int t.base_info.B.sector_size)) [ cluster ]
      >>*= fun () ->
      Cluster.incr_refcount t (Int64.div l1_table_offset cluster_size)
      >>*= fun () ->
      Lwt.return (`Ok t)
    | Result.Error (`Msg m) ->
      Lwt.return (`Error (`Unknown m))
end
