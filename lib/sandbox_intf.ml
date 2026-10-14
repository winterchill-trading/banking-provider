(** What a sandbox can trigger that a customer cannot: the counterpart of a provider's
    simulator endpoints. Optional for an implementation of {!Provider.S}; the fake
    implements all of it, and {!Conformance} needs it to fund accounts and approve
    customers. *)

open! Core
open Async_kernel
open Payments_core
module Ids = Card_core.Ids
module Response_code = Card_core.Response_code

module Kyc_decision = struct
  type t =
    | Approve
    | Reject of string
    | Request_resubmission of Kyc_core.Person.Field.t list
  [@@deriving sexp, compare, equal]
end

module Kyc_outcome = struct
  type t =
    | Approved
    | Pending_review
    | Rejected of string
  [@@deriving sexp, compare, equal]
end

module Kyc_simulation = struct
  type t =
    | Manual
    | Decide of
        { outcome : Kyc_outcome.t
        ; delay : Time_ns.Span.t
        }
  [@@deriving sexp, compare, equal]
end

module Deposit_outcome = struct
  type t =
    | Credit
    | Bounce of Iso_reason.t
  [@@deriving sexp, compare, equal]
end

module Deposit_simulation = struct
  type t =
    { delay : Time_ns.Span.t
    ; outcome : Deposit_outcome.t
    }
  [@@deriving sexp, compare, equal]

  let default = { delay = Time_ns.Span.zero; outcome = Credit }
end

let unsupported_tag = "not supported by this sandbox"

let unsupported ~operation =
  Deferred.Or_error.error_s [%message unsupported_tag (operation : string)]
;;

let is_unsupported error =
  match Error.sexp_of_t error with
  | Sexp.List (Atom tag :: _) -> String.equal tag unsupported_tag
  | _ -> false
;;

module type S = sig
  type t

  (** An incoming payment to [account] on [rail]; returns our id for it (the
      [Incoming_transfer] event's [transfer]). *)
  val simulate_deposit
    :  t
    -> account:Account_ref.t
    -> rail:Rail.t
    -> Money.Amount.t
    -> Transfer.Id.t Or_error.t Deferred.t

  (** Decides the hosted identity steps (document, liveness) and the provider status. *)
  val simulate_kyc_decision
    :  t
    -> Customer_ref.t
    -> Kyc_decision.t
    -> unit Or_error.t Deferred.t

  (** A card-not-present authorization for the merchant's amount (in the card's billing
      currency); returns the answer given. *)
  val simulate_card_auth
    :  t
    -> Ids.Card_id.t
    -> Card_core.Merchant.t
    -> Response_code.t Or_error.t Deferred.t

  (** The scheme's answer to an outgoing transfer (settle, reject, return, ...). *)
  val simulate_transfer_outcome
    :  t
    -> Transfer.Id.t
    -> Transfer_update.t
    -> unit Or_error.t Deferred.t

  (** Fixes the answer the receiving bank gives for [beneficiary]: published as a
      [Payee_check] event, and returned by every later {!Provider.S.verify_payee} for that
      beneficiary. *)
  val simulate_payee_check
    :  t
    -> Beneficiary.Id.t
    -> Beneficiary.Payee_check.t
    -> unit Or_error.t Deferred.t

  (** A [Ping] event. *)
  val ping : t -> unit Or_error.t Deferred.t

  (** {2 Simulation settings}

      How the sandbox answers on its own, so a demo or a test can drive timing without
      calling the [simulate_*] values above. Without [customer] the setting is the default
      for every customer; with it, an override for that customer that wins over the
      default (set it again to change it). A sandbox without such controls answers
      [Sandbox.unsupported]. *)

  (** [Manual] (the default): KYC waits for {!simulate_kyc_decision}.
      [Decide { outcome; delay }]: [delay] after the customer starts a hosted verification
      step (document, liveness), on the implementation's clock, the case is decided:
      [Approved] and [Rejected] as {!simulate_kyc_decision} would; [Pending_review]
      verifies the hosted steps and submits the case, which then waits in review for
      {!simulate_kyc_decision}. Starting another hosted step before the decision restarts
      the delay, so the decision comes [delay] after the last one. *)
  val set_kyc_simulation
    :  t
    -> ?customer:Customer_ref.t
    -> Kyc_simulation.t
    -> unit Or_error.t Deferred.t

  (** How {!simulate_deposit} lands (the default is [Deposit_simulation.default]: at once,
      credited). With a [delay], the deposit is reported at once as pending and settles
      [delay] later on the implementation's clock; [Bounce reason] rejects it with
      [reason] instead of settling, and nothing is credited. [customer] is the owner of
      the account the deposit goes to. *)
  val set_deposit_simulation
    :  t
    -> ?customer:Customer_ref.t
    -> Deposit_simulation.t
    -> unit Or_error.t Deferred.t
end

module type Sandbox = sig
  module Kyc_decision : sig
    type t = Kyc_decision.t =
      | Approve
      | Reject of string
      | Request_resubmission of Kyc_core.Person.Field.t list
    [@@deriving sexp, compare, equal]
  end

  (** What an automatic KYC decision ({!Kyc_simulation.Decide}) does. *)
  module Kyc_outcome : sig
    type t = Kyc_outcome.t =
      | Approved
      | Pending_review (** hosted steps verified, case submitted, left in review *)
      | Rejected of string (** the reason the case and its hosted steps carry *)
    [@@deriving sexp, compare, equal]
  end

  module Kyc_simulation : sig
    type t = Kyc_simulation.t =
      | Manual (** wait for {!S.simulate_kyc_decision} *)
      | Decide of
          { outcome : Kyc_outcome.t
          ; delay : Time_ns.Span.t
          (** after the last hosted step starts; [zero] decides at once *)
          }
    [@@deriving sexp, compare, equal]
  end

  module Deposit_outcome : sig
    type t = Deposit_outcome.t =
      | Credit
      | Bounce of Iso_reason.t
      (** the receiving bank refuses it ([AC04] closed account, [AG01] forbidden, ...) *)
    [@@deriving sexp, compare, equal]
  end

  module Deposit_simulation : sig
    type t = Deposit_simulation.t =
      { delay : Time_ns.Span.t (** from the report to the settlement or the bounce *)
      ; outcome : Deposit_outcome.t
      }
    [@@deriving sexp, compare, equal]

    (** No delay, credited: what a sandbox does unless told otherwise. *)
    val default : t
  end

  (** The answer of a sandbox that has no such control, e.g. an adapter whose provider
      cannot simulate a KYC outcome: an error that {!is_unsupported} recognizes. *)
  val unsupported : operation:string -> 'a Or_error.t Deferred.t

  (** Whether an error is an {!unsupported} answer, so a test can skip rather than fail. *)
  val is_unsupported : Error.t -> bool

  module type S = S
end
