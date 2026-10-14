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
end

module type Sandbox = sig
  module Kyc_decision : sig
    type t = Kyc_decision.t =
      | Approve
      | Reject of string
      | Request_resubmission of Kyc_core.Person.Field.t list
    [@@deriving sexp, compare, equal]
  end

  module type S = S
end
