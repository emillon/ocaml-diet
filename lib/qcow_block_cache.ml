(*
 * Copyright (C) 2017 Docker Inc
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

let kib = 1024L
let mib = Int64.mul kib 1024L

open Qcow_types
module Cstructs = Qcow_cstructs

module RangeLocks = struct

  type t = {
    mutable locked: Int64.IntervalSet.t;
    c: unit Lwt_condition.t;
  }
  (** A set of exclusively locked intervals *)

  let create () =
    let locked = Int64.IntervalSet.empty in
    let c = Lwt_condition.create () in
    { locked; c }
  let with_lock t i f =
    let open Lwt.Infix in
    let set = Int64.IntervalSet.(add i empty) in
    let rec get_lock () =
      if Int64.IntervalSet.(is_empty @@ inter t.locked set) then begin
        t.locked <- Int64.IntervalSet.(union t.locked set);
        Lwt.return_unit
      end else begin
        Lwt_condition.wait t.c
        >>= fun () ->
        get_lock ()
      end in
    let put_lock () =
      t.locked <- Int64.IntervalSet.(diff t.locked set);
      Lwt.return_unit in
    get_lock ()
    >>= fun () ->
    Lwt.finalize f put_lock

end

module Make(B: Qcow_s.RESIZABLE_BLOCK) = struct
  type 'a io = 'a Lwt.t
  type page_aligned_buffer = Cstruct.t
  type error = B.error
  type write_error = B.write_error
  let pp_error = B.pp_error
  let pp_write_error = B.pp_write_error

  type t = {
    base: B.t;
    sector_size: int;
    max_size_bytes: int64;
    mutable current_size_bytes: int64;
    mutable in_cache: Int64.IntervalSet.t;
    mutable cache: Cstruct.t Int64.Map.t;
    locks: RangeLocks.t;
    mutable disconnect_request: bool;
    disconnect_m: Lwt_mutex.t;
    write_back_m: Lwt_mutex.t;
  }

  let get_info t = B.get_info t.base

  let lazy_write_back t =
    Lwt_mutex.with_lock t.write_back_m
      (fun () ->
        Int64.IntervalSet.fold_s
          (fun i err -> match err with
            | Error e -> Lwt.return (Error e)
            | Ok () ->
              RangeLocks.with_lock t.locks i
                (fun () ->
                  let x, y = Int64.IntervalSet.Interval.(x i, y i) in
                  let rec bufs acc sector =
                    if sector > y then List.rev acc else begin
                      assert(Int64.Map.mem sector t.cache);
                      let buf = Int64.Map.find sector t.cache in
                      t.in_cache <- Int64.IntervalSet.remove i t.in_cache;
                      t.cache <- Int64.Map.remove sector t.cache;
                      bufs (buf :: acc) (Int64.succ sector)
                    end in
                  t.current_size_bytes <- Int64.sub t.current_size_bytes len;
                  B.write t.base x (bufs [] x)
                )
          ) t.in_cache (Ok ())
      )

  let flush t =
    let open Lwt.Infix in
    lazy_write_back t
    >>= function
    | Error e -> Lwt.return (Error e)
    | Ok () ->
    B.flush t.base

  let connect ?(max_size_bytes = Int64.mul 100L mib) base =
    let open Lwt.Infix in
    B.get_info base
    >>= fun info ->
    let sector_size = info.Mirage_block.sector_size in
    let current_size_bytes = 0L in
    let in_cache = Int64.IntervalSet.empty in
    let cache = Int64.Map.empty in
    let locks = RangeLocks.create () in
    let disconnect_request = false in
    let disconnect_m = Lwt_mutex.create () in
    let write_back_m = Lwt_mutex.create () in
    let t = {
      base; sector_size; max_size_bytes; current_size_bytes; in_cache; cache;
      locks; disconnect_request; disconnect_m; write_back_m;
    } in
    Lwt.return t

  let disconnect t =
    let open Lwt.Infix in
    Lwt_mutex.with_lock t.disconnect_m
      (fun () ->
        t.disconnect_request <- true;
        Lwt.return_unit
      )
    >>= fun () ->
    (* There can be no more in-progress writes *)
    flush t
    >>= fun _ ->
    B.disconnect t.base

  (* Call [f sector buf] for every sector from [start] up to the length of [bufs] *)
  let rec per_sector sector_size start bufs f = match bufs with
    | [] -> Lwt.return (Ok ())
    | b :: bs ->
      let open Lwt.Infix in
      let rec loop sector remaining =
        if Cstruct.len remaining = 0 then Lwt.return (Ok sector) else begin
          assert (Cstruct.len remaining >= sector_size);
          let first = Cstruct.sub remaining 0 sector_size in
          f sector first
          >>= function
          | Error e -> Lwt.return (Error e)
          | Ok () -> loop (Int64.succ sector) (Cstruct.shift remaining sector_size)
        end in
      loop start b
      >>= function
      | Error e -> Lwt.return (Error e)
      | Ok start' -> per_sector sector_size start' bs f

  let read t start bufs =
    let len = Int64.of_int @@ Cstructs.len bufs in
    let i = Int64.IntervalSet.Interval.make start Int64.(pred @@ add start (div len (of_int t.sector_size))) in
    let set = Int64.IntervalSet.(add i empty) in
    if t.disconnect_request
    then Lwt.return (Error `Disconnected)
    else RangeLocks.with_lock t.locks i
      (fun () ->
        if Int64.IntervalSet.(is_empty @@ inter t.in_cache set)
        then B.read t.base start bufs (* consider adding it to cache *)
        else begin
          per_sector t.sector_size start bufs
            (fun sector buf ->
              if Int64.Map.mem sector t.cache then begin
                let from_cache = Int64.Map.find sector t.cache in
                Cstruct.blit from_cache 0 buf 0 t.sector_size;
                Lwt.return (Ok ())
              end else B.read t.base sector [ buf ]
            )
        end
      )

  let write t start bufs =
    let open Lwt.Infix in
    let len = Int64.of_int @@ Cstructs.len bufs in
    ( if Int64.(add t.current_size_bytes len) > t.max_size_bytes
      then lazy_write_back t
      else Lwt.return (Ok ()) )
    >>= function
    | Error e -> Lwt.return (Error e)
    | Ok () ->
      let i = Int64.IntervalSet.Interval.make start Int64.(pred @@ add start (div len (of_int t.sector_size))) in
      (* Prevent new writes entering the cache after the disconnect has started *)
      Lwt_mutex.with_lock t.disconnect_m
        (fun () ->
          if t.disconnect_request
          then Lwt.return (Error `Disconnected)
          else RangeLocks.with_lock t.locks i
            (fun () ->
              per_sector t.sector_size start bufs
                (fun sector buf ->
                  assert (Cstruct.len buf = t.sector_size);
                  if not(Int64.Map.mem sector t.cache) then begin
                    t.in_cache <- Int64.IntervalSet.(add i t.in_cache);
                    t.current_size_bytes <- Int64.(add t.current_size_bytes (of_int t.sector_size));
                  end;
                  t.cache <- Int64.Map.add sector buf t.cache;
                  Lwt.return (Ok ())
                )
            )
        )

  let resize t new_size =
    B.resize t.base new_size
end
