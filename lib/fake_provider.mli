(** An in-memory, deterministic provider for tests, offline mode and the web app's mock
    mode.

    {b Deterministic.} Ids come from counters ([cus_000001], [acc_000001], [evt_000001],
    ...), time from the injected [time_source], and nothing reads the wall clock or a
    random generator, so the same calls give the same events, ids and balances.

    {b Booked.} Every movement is booked into the {!Ledger.Journal.t} given at creation
    with {!Payments_core.Booking} (transfers, deposits), {!Payments_core.Swap} (swaps) and
    {!Card_core.Booking} (card authorizations, clearings, reversals, refunds), with the
    event id in each idempotency key. Card authorizations are decided by
    {!Card_core.Decision} (card status, limits, funds), as if the merchant had passed
    3-D Secure. A
    balance is what the journal says, so the books always balance and an account cannot
    go below zero.

    {b Settlement.} [Immediate] completes outgoing transfers, on-chain confirmations and
    card clearings at once; [Delayed span] schedules them on the time source (advance a
    synthetic clock to see them); [Manual] leaves them to {!Provider.Sandbox.simulate_transfer_outcome}
    and {!clear_card_auth}.

    {b Events.} Each event goes to every subscriber of {!events} and is also kept as a
    signed webhook delivery ({!webhook_deliveries}), so a test can redeliver them, out of
    order, through {!ingest_webhook} the way a real provider would.

    {b SCA.} Transfers, swaps, standing orders and card details need a challenge, answered
    with {!sandbox_code}, unless [sca] is off in the config. *)

open! Core
open Async_kernel
open Payments_core

module Settlement : sig
  type t =
    | Immediate
    | Delayed of Time_ns.Span.t
    | Manual
  [@@deriving sexp, compare, equal]
end

module Config : sig
  type t =
    { settlement : Settlement.t
    ; sca : bool
    ; fee : Rail.t -> Money.Currency.t -> Money.Fee.t option (** default: free *)
    ; rates : (Money.Currency.t * Money.Currency.t * string) list
    (** [(base, quote, price)] market rates for swaps, e.g. [(btc, eur, "60000")] *)
    ; swap_spread_bps : int
    ; webhook_key : Sensitive.t (** signs {!webhook_deliveries} *)
    ; auto_enrich : bool (** assign IBANs and addresses when an account opens *)
    }

  (** Immediate settlement, SCA on, no fees, BTC, ETH, USDC and USDT rates against EUR,
      no spread, a fixed test webhook key, no auto-enrichment. *)
  val default : t
end

type t

(** The code that answers every challenge and verification code. *)
val sandbox_code : string

(** Opens the system accounts the booking rules need in [journal] (idempotent, so a
    journal that already has them is fine). [time_source] should be the journal's. *)
val create
  :  ?config:Config.t
  -> time_source:[> read ] Time_source.T1.t
  -> journal:Ledger.Journal.t
  -> unit
  -> t Or_error.t

include Provider.S with type t := t
include Provider.Sandbox with type t := t

(** {2 Fake-only controls} *)

(** Pays every confirmed standing order that is due at the time source's current time;
    returns our ids of the transfers it started. *)
val run_standing_orders : t -> Transfer.Id.t list Or_error.t Deferred.t

(** Clears an approved card authorization: the whole remainder by default, part of it,
    or more than it (an over-capture, e.g. a tip). *)
val clear_card_auth
  :  t
  -> Card_core.Ids.Auth_id.t
  -> ?amount:Money.Amount.t
  -> unit
  -> unit Or_error.t Deferred.t

(** Releases an approved, uncleared authorization (or part of it). *)
val reverse_card_auth
  :  t
  -> Card_core.Ids.Auth_id.t
  -> ?amount:Money.Amount.t
  -> unit
  -> unit Or_error.t Deferred.t

(** A merchant refund of [merchant]'s amount to the card's account: a credit clearing,
    a new credit. *)
val refund_card
  :  t
  -> Card_core.Ids.Card_id.t
  -> Card_core.Merchant.t
  -> unit Or_error.t Deferred.t

(** A verification-of-payee answer for a beneficiary, published as a [Payee_check]
    event. *)
val simulate_payee_check
  :  t
  -> Beneficiary.Id.t
  -> Beneficiary.Payee_check.t
  -> unit Or_error.t Deferred.t

(** Every event so far as a signed delivery, in publish order. *)
val webhook_deliveries : t -> Webhook.Request.t list

(** Every event so far, in publish order. *)
val published : t -> Event.t list

(** Our ledger account behind a provider account. *)
val ledger_account : t -> Account_ref.t -> Ledger.Account_id.t Or_error.t

(** Failures inside scheduled (delayed) work, which has no caller to return them to. *)
val background_errors : t -> Error.t list
