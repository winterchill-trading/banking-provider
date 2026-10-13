(* The consumer from the README, kept here so it keeps compiling. *)

open! Core
open Async
open Banking_provider

module Consumer (P : Provider.S) = struct
  let run provider ~transfers =
    let inbox = Inbox.create () in
    Pipe.iter_without_pushback (P.events provider) ~f:(fun (event : Event.t) ->
      match Inbox.accept inbox event with
      | Error e -> Log.Global.error_s [%sexp (e : Error.t)]
      | Ok Duplicate -> () (* redelivered: already applied *)
      | Ok New ->
        (match event.kind with
         | Transfer { transfer; update; _ } ->
           Hashtbl.change transfers transfer ~f:(fun current ->
             Option.map current ~f:(fun t ->
               match Transfer_update.apply update t ~at:event.at () with
               | Ok (Changed t) -> t
               | Ok Stale | Error _ -> t))
         | _ -> ()))
  ;;
end

module Fake_consumer = Consumer (Fake_provider)

let (_ :
      Fake_provider.t
      -> transfers:(Payments_core.Transfer.Id.t, Payments_core.Transfer.t) Hashtbl.t
      -> unit Deferred.t)
  =
  Fake_consumer.run
;;
