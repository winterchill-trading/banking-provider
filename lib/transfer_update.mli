(** A change to a transfer as a provider reports it, and how it applies to our
    {!Payments_core.Transfer.t}.

    Providers deliver these at least once and in no guaranteed order, so {!apply} treats a
    report that the transfer has already moved past (a [Pending] after [Settled], the same
    status twice) as {!Applied.Stale} rather than an error. Anything else the transfer's
    state machine refuses is an error: a real inconsistency to look at. *)

open! Core
open Payments_core

type t =
  | Submitted (** accepted by the provider for execution *)
  | Status_report of
      { status : Iso20022.Transaction_status.t
      ; reason : Iso_reason.Stable.V1.t option (** required with [RJCT] *)
      ; value_date : Date.Stable.V1.t option
      } (** a SEPA pacs.002 status, as received *)
  | Pending
  | Settled (** also a late settlement after an SCT Inst timeout *)
  | Rejected of Iso_reason.Stable.V1.t
  | Failed of Transfer.Failure_reason.t
  | Timed_out (** SCT Inst: no confirmation within ten seconds *)
  | Returned of Iso_reason.Stable.V1.t
  | Recall_requested of Iso_reason.Stable.V1.t
  | Recall_answer of
      { accepted : bool
      ; reason : Iso_reason.Stable.V1.t (** [FOCR] when accepted *)
      }
  | Confirmations of
      { tx_hash : string
      ; block_hash : string
      ; confirmations : int
      ; finalized : bool
      } (** on-chain progress; the transfer settles when the policy is met *)
  | Reorged of { tx_hash : string }
  | Lightning_paid of { preimage : string } (** hex; proves payment of the invoice *)
  | Cancelled
[@@deriving bin_io, sexp, compare, equal]

module Applied : sig
  type t =
    | Changed of Transfer.t (** status or details moved *)
    | Stale (** already there or past it: a redelivery or an out-of-order report *)
  [@@deriving sexp, compare, equal]
end

(** [eur_value] feeds the on-chain confirmation policy (6 blocks above EUR 10 000). *)
val apply
  :  t
  -> Transfer.t
  -> ?eur_value:Money.Amount.t
  -> at:Time_ns.t
  -> unit
  -> Applied.t Or_error.t
