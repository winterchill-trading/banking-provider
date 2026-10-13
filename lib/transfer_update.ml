open! Core
open Payments_core

type t =
  | Submitted
  | Status_report of
      { status : Iso20022.Transaction_status.t
      ; reason : Iso_reason.Stable.V1.t option
      ; value_date : Date.Stable.V1.t option
      }
  | Pending
  | Settled
  | Rejected of Iso_reason.Stable.V1.t
  | Failed of Transfer.Failure_reason.t
  | Timed_out
  | Returned of Iso_reason.Stable.V1.t
  | Recall_requested of Iso_reason.Stable.V1.t
  | Recall_answer of
      { accepted : bool
      ; reason : Iso_reason.Stable.V1.t
      }
  | Confirmations of
      { tx_hash : string
      ; block_hash : string
      ; confirmations : int
      ; finalized : bool
      }
  | Reorged of { tx_hash : string }
  | Lightning_paid of { preimage : string }
  | Cancelled
[@@deriving bin_io, sexp, compare, equal]

module Applied = struct
  type t =
    | Changed of Transfer.t
    | Stale
  [@@deriving sexp, compare, equal]
end

(* How far along the happy path a status is. A report for an earlier stage than the
   transfer is at was overtaken by a later one. *)
let stage : Transfer.Status.t -> int = function
  | Draft -> 0
  | Awaiting_sca -> 1
  | Submitted -> 2
  | Pending | Reorged -> 3
  | Timed_out -> 4
  | Settled -> 5
  | Recall_requested _ | Recall_refused _ -> 6
  | Rejected _ | Failed _ | Returned _ | Recalled | Cancelled -> 7
;;

let to_status (t : t) : Transfer.Status.t option =
  match t with
  | Submitted -> Some Submitted
  | Pending -> Some Pending
  | Settled -> Some Settled
  | Rejected r -> Some (Rejected r)
  | Failed r -> Some (Failed r)
  | Timed_out -> Some Timed_out
  | Returned r -> Some (Returned r)
  | Recall_requested r -> Some (Recall_requested r)
  | Recall_answer { accepted = true; _ } -> Some Recalled
  | Recall_answer { accepted = false; reason } -> Some (Recall_refused reason)
  | Reorged _ -> Some Reorged
  | Cancelled -> Some Cancelled
  | Status_report _ | Confirmations _ | Lightning_paid _ -> None
;;

let is_stale (transfer : Transfer.t) (target : Transfer.Status.t) =
  Transfer.Status.equal transfer.status target
  || Transfer.Status.is_final transfer.status
  ||
  match target with
  | Submitted | Pending -> stage transfer.status > stage target
  (* A late settlement after a timeout is legal; a timeout after settling is stale. *)
  | Timed_out -> stage transfer.status >= stage Settled
  | _ -> false
;;

let changed (before : Transfer.t) (after : Transfer.t) : Applied.t =
  if Transfer.equal before after then Stale else Changed after
;;

let apply t (transfer : Transfer.t) ?eur_value ~at () : Applied.t Or_error.t =
  let open Or_error.Let_syntax in
  match t with
  | Status_report { status; reason; value_date } ->
    if Transfer.Status.is_final transfer.status
    then Ok Stale
    else (
      let%map after =
        Transfer.apply_status_report transfer status ?reason ?value_date ~at ()
      in
      changed transfer after)
  | Confirmations { tx_hash; block_hash; confirmations; finalized } ->
    (match transfer.details with
     | Onchain d when d.confirmations > confirmations && not finalized -> Ok Applied.Stale
     | _ ->
       if Transfer.Status.is_final transfer.status
       then Ok Stale
       else (
         let%map after =
           Transfer.record_confirmations
             transfer
             ~tx_hash
             ~block_hash
             ~confirmations
             ~finalized
             ?eur_value
             ~at
             ()
         in
         changed transfer after))
  | Lightning_paid { preimage } ->
    if is_stale transfer Settled
    then Ok Stale
    else (
      let%map after = Transfer.settle_lightning transfer ~preimage ~at in
      Applied.Changed after)
  | _ ->
    (match to_status t with
     | None -> Ok Stale
     | Some target ->
       if is_stale transfer target
       then Ok Stale
       else (
         let%map after = Transfer.transition transfer ~to_:target ~at in
         Applied.Changed after))
;;
