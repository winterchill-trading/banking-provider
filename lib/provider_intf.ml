(** What an application needs from a banking-as-a-service provider. *)

open! Core
open Async_kernel
open Payments_core
module Card = Card_core.Card
module Ids = Card_core.Ids
module Limits = Card_core.Limits
module Pan_display_token = Card_core.Pan_display_token
module Response_code = Card_core.Response_code

(** Every call is asynchronous and returns [Or_error]: a provider is a remote service, and
    a refusal is an answer, not an exception.

    {b Idempotency.} Calls that create something are keyed by an id the caller chose,
    which the implementation sends as the provider's idempotency key: creating a customer
    with the same [customer_id], initiating a transfer with the same [Transfer.Id.t] or
    issuing a card with the same [request_id] again returns what the first call created
    and never creates a second one. So an outbox relay may resend any of these.

    {b Results arrive as events.} An initiating response is never the final state of a
    payment: completion, rejection, returns, card activity and KYC decisions arrive on
    {!events}, normalized ({!Event.t}), at least once and in any order. Status queries
    ({!transfer}, {!kyc_status}) exist for reconciliation and for a poll after a missed
    webhook.

    {b SCA.} Operations that move money may stop with a {!Sca_challenge.t}; answer it with
    {!confirm_sca} and the operation proceeds. *)
module type S = sig
  type t

  (** Short name of the implementation, e.g. ["fake"]; used as the KYC actor. *)
  val name : t -> string

  (** {2 Customers} *)

  val create_customer
    :  t
    -> customer_id:Kyc_core.Customer_id.t
    -> person:Kyc_core.Person.t
    -> Customer.t Or_error.t Deferred.t

  val update_customer
    :  t
    -> Customer_ref.t
    -> person:Kyc_core.Person.t
    -> unit Or_error.t Deferred.t

  (** Sends a code (e-mail, mobile) or opens a hosted session (document, liveness). *)
  val start_verification
    :  t
    -> Customer_ref.t
    -> Kyc_core.Verification.Step.t
    -> Customer.Verification_session.t Or_error.t Deferred.t

  (** Answers a [Code_sent] step with the code the customer received. A wrong code gives
      [Failed]; start the step again to retry. *)
  val complete_verification
    :  t
    -> Customer_ref.t
    -> Kyc_core.Verification.Step.t
    -> code:Sensitive.t
    -> Kyc_core.Verification.State.t Or_error.t Deferred.t

  val kyc_status : t -> Customer_ref.t -> Customer.Kyc_status.t Or_error.t Deferred.t

  (** {2 Accounts} *)

  (** Usually only after KYC approval. *)
  val open_account
    :  t
    -> Customer_ref.t
    -> Money.Currency.t
    -> Account.t Or_error.t Deferred.t

  val accounts : t -> Customer_ref.t -> Account.t list Or_error.t Deferred.t
  val balance : t -> Account_ref.t -> Account.Balance.t Or_error.t Deferred.t

  (** Assigns an IBAN or a deposit address if the account has none yet; returns the
      account with its addresses. Idempotent. *)
  val enrich_account : t -> Account_ref.t -> Account.t Or_error.t Deferred.t

  val statement
    :  t
    -> Account_ref.t
    -> from:Time_ns.t
    -> until:Time_ns.t
    -> Statement.t Or_error.t Deferred.t

  (** {2 Transfers} *)

  val quote_fee
    :  t
    -> from:Account_ref.t
    -> rail:Rail.t
    -> Money.Amount.t
    -> Transfer_info.Fee_quote.t Or_error.t Deferred.t

  (** Sends an outgoing [Draft] (from {!Payments_core.Transfer.draft}) from [from]. The
      draft's id is the idempotency key. The transfer's own [account] field names our
      ledger account and is not sent. *)
  val initiate_transfer
    :  t
    -> from:Account_ref.t
    -> Transfer.t
    -> Transfer_info.t Sca_challenge.Or_challenge.t Or_error.t Deferred.t

  val transfer : t -> Transfer.Id.t -> Transfer_info.t Or_error.t Deferred.t

  (** Only before submission to the scheme. *)
  val cancel_transfer : t -> Transfer.Id.t -> Transfer_info.t Or_error.t Deferred.t

  (** Answers a challenge from any operation. *)
  val confirm_sca
    :  t
    -> Sca.Id.t
    -> code:Sensitive.t
    -> Sca_challenge.Result.t Or_error.t Deferred.t

  (** {2 Payee checks} *)

  (** Asks the receiving bank whether [beneficiary]'s name matches the account it names
      (UK Confirmation of Payee, SEPA Verification of Payee), on behalf of [customer]
      before a payment. Destinations no scheme checks (crypto, Lightning, internal) answer
      [Not_possible]; a time-out or a scheme outage is [Unavailable], not an error. An
      error means the request itself failed (unknown customer, provider refusal). A
      provider may also publish the answer as a [Payee_check] event. *)
  val verify_payee
    :  t
    -> customer:Customer_ref.t
    -> Beneficiary.t
    -> Beneficiary.Payee_check.t Or_error.t Deferred.t

  (** {2 Swaps} *)

  (** Sells [sell] from [from] for the currency of [to_]. *)
  val quote_swap
    :  t
    -> from:Account_ref.t
    -> to_:Account_ref.t
    -> sell:Money.Amount.t
    -> Swap.Quote.t Or_error.t Deferred.t

  (** The result arrives as [Swap_executed] or [Swap_failed]. *)
  val execute_swap
    :  t
    -> Swap.Id.t
    -> unit Sca_challenge.Or_challenge.t Or_error.t Deferred.t

  (** {2 Cards} *)

  val issue_virtual_card
    :  t
    -> request_id:string
    -> Customer_ref.t
    -> account:Account_ref.t
    -> Card_info.t Or_error.t Deferred.t

  val card : t -> Ids.Card_id.t -> Card_info.t Or_error.t Deferred.t
  val cards : t -> Customer_ref.t -> Card_info.t list Or_error.t Deferred.t

  (** Freeze ([Frozen]), unfreeze ([Active]), block or destroy, as card-core's transition
      table allows. *)
  val set_card_status
    :  t
    -> Ids.Card_id.t
    -> Card.Status.t
    -> Card_info.t Or_error.t Deferred.t

  val set_card_limits
    :  t
    -> Ids.Card_id.t
    -> Limits.t
    -> Card_info.t Or_error.t Deferred.t

  (** A short-lived token for the provider's hosted card-number component. Needs SCA: the
      first call returns a challenge; after it is accepted, call again. *)
  val card_details_token
    :  t
    -> Ids.Card_id.t
    -> Pan_display_token.t Sca_challenge.Or_challenge.t Or_error.t Deferred.t

  (** {2 Standing orders} *)

  (** Registers a standing order (from {!Payments_core.Standing_order.create}) paid from
      [from]; confirmed once by SCA, then each run arrives as a [Standing_order_run]
      event. *)
  val create_standing_order
    :  t
    -> from:Account_ref.t
    -> Standing_order.t
    -> Standing_order_ref.t Sca_challenge.Or_challenge.t Or_error.t Deferred.t

  val cancel_standing_order : t -> Standing_order_ref.t -> unit Or_error.t Deferred.t

  (** {2 Events} *)

  (** A new subscription: every event published from now on, normalized. Close the reader
      to unsubscribe. *)
  val events : t -> Event.t Pipe.Reader.t

  (** Verifies a webhook delivery on its raw bytes with the provider's own material,
      normalizes it and publishes the events to every subscriber; returns them. A bad
      signature is an error and publishes nothing. *)
  val ingest_webhook : t -> Webhook.Request.t -> Event.t list Or_error.t Deferred.t
end

(** An optional capability next to {!S}: a payee check that also returns what the
    receiving bank said about the account besides the name (its currency). Providers that
    offer it implement this signature too; {!Payee_details_of_verify} adapts any {!S} that
    does not, with no currency. *)
module type Payee_details = sig
  type t

  (** {!S.verify_payee}, with the receiving account's currency when the provider knows it.
      The [result] is the one {!S.verify_payee} would give. *)
  val verify_payee_details
    :  t
    -> customer:Customer_ref.t
    -> Beneficiary.t
    -> Payee_check_result.t Or_error.t Deferred.t
end

module Payee_details_of_verify (P : S) : Payee_details with type t = P.t = struct
  type t = P.t

  let verify_payee_details t ~customer beneficiary =
    Deferred.Or_error.map (P.verify_payee t ~customer beneficiary) ~f:(fun result ->
      Payee_check_result.create result)
  ;;
end

module type Provider = sig
  module type S = S
  module type Payee_details = Payee_details

  (** {!Payee_details} over {!S.verify_payee}, never knowing the currency. *)
  module Payee_details_of_verify (P : S) : Payee_details with type t = P.t
end
