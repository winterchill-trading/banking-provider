open! Core

type t = Event.t Event_id.Table.t

let create () = Event_id.Table.create ()

module Outcome = struct
  type t =
    | New
    | Duplicate
  [@@deriving sexp, compare, equal]
end

let accept t (event : Event.t) : Outcome.t Or_error.t =
  match Hashtbl.find t event.id with
  | None ->
    Hashtbl.set t ~key:event.id ~data:event;
    Ok New
  | Some seen when Event.equal seen event -> Ok Duplicate
  | Some _ ->
    Or_error.error_s
      [%message "event id reused with different content" ~id:(event.id : Event_id.t)]
;;

let mem t id = Hashtbl.mem t id
let length t = Hashtbl.length t
