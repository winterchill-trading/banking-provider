(** An in-memory, deterministic provider for tests, offline mode and the web app's mock
    mode.

    {b Deterministic.} Ids come from counters ([cus_000001], [acc_000001], [evt_000001],
    ...), time from the injected [time_source], and nothing reads the wall clock or a
    random generator, so the same calls give the same events, ids and balances.

    {b Booked.} Every movement is booked into the {!Ledger.Journal.t} given at creation
    with {!Payments_core.Booking} (transfers, deposits), {!Payments_core.Swap} (swaps) and
    {!Card_core.Booking} (card authorizations, clearings, reversals, refunds), with the
    event id in each idempotency key. Card authorizations are decided by
    {!Card_core.Decision} (card status, limits, funds), as if the merchant had passed 3-D
    Secure. A balance is what the journal says, so the books always balance and an account
    cannot go below zero.

    {b Settlement.} [Immediate] completes outgoing transfers, on-chain confirmations and
    card clearings at once; [Delayed span] schedules them on the time source (advance a
    synthetic clock to see them); [Manual] leaves them to
    {!Sandbox.S.simulate_transfer_outcome} and {!clear_card_auth}.

    {b Events.} Each event goes to every subscriber of {!events} and is also kept as a
    signed webhook delivery ({!webhook_deliveries}), so a test can redeliver them, out of
    order, through {!ingest_webhook} the way a real provider would.

    {b SCA.} Transfers, swaps, standing orders and card details need a challenge, answered
    with {!sandbox_code}, unless [sca] is off in the config.

    {b Currencies.} EUR accounts get a German IBAN, GBP accounts a UK sort code
    ([99-00-00], which no bank uses) and account number, and USD accounts routing number

    [123456780] (valid check digit, not looked up) and a ten-digit account number; crypto
    accounts get an address on their network. GBP moves on Faster Payments (settled at
    once), CHAPS and Bacs (pending, then settled); USD on RTP and Fedwire (settled at
    once) and ACH (pending, then settled).

    {b Payee checks.} {!verify_payee} answers what {!simulate_payee_check} last fixed for
    the beneficiary. Otherwise it goes by the last two characters of the account number or
    IBAN: [96] is [Unavailable], [97] [Close_match] (the name with initials), [98]
    [No_match], [99] [Account_not_found], anything else [Match]. Crypto, Lightning,
    internal and US destinations (no US scheme checks names) are [Not_possible]. *)

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

  (** Immediate settlement, SCA on, no fees, BTC, ETH, USDC and USDT rates against EUR, no
      spread, a fixed test webhook key, no auto-enrichment. *)
  val default : t
end

type t

(** The code that answers every challenge and verification code. *)
val sandbox_code : string

(** Opens the system accounts the booking rules need in [journal] (idempotent, so a
    journal that already has them is fine). [time_source] should be the journal's. *)
val create
  :  ?config:Config.t
  -> ?counters:(string * int) list
  -> time_source:[> read ] Time_source.T1.t
  -> journal:Ledger.Journal.t
  -> unit
  -> t Or_error.t

(** The id counters by prefix ([cus], [acc], [evt], [card], ...), sorted. Ids come from
    them, so a service that keeps the journal across restarts saves them and passes them
    back to {!create} as [counters]; otherwise a restarted fake hands out [cus_000001]
    again. *)
val counters : t -> (string * int) list

include Provider.S with type t := t
include Sandbox.S with type t := t

(** {2 Fake-only controls} *)

(** Pays every confirmed standing order that is due at the time source's current time;
    returns our ids of the transfers it started. *)
val run_standing_orders : t -> Transfer.Id.t list Or_error.t Deferred.t

(** Clears an approved card authorization: the whole remainder by default, part of it, or
    more than it (an over-capture, e.g. a tip). *)
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

(** Expires every authorization whose hold has lapsed at the time source's current time (7
    days, 30 for lodging, car rental and cruise): the rest of the hold goes back and an
    [Expiry] event is published. Returns their ids. *)
val expire_card_auths : t -> Card_core.Ids.Auth_id.t list Or_error.t Deferred.t

(** An advice: an authorization the scheme answered for us (stand-in) with [response],
    recorded as decided. An approved advice holds the funds like any authorization. *)
val simulate_card_advice
  :  t
  -> Card_core.Ids.Card_id.t
  -> Card_core.Merchant.t
  -> response:Card_core.Response_code.t
  -> Card_core.Ids.Auth_id.t Or_error.t Deferred.t

(** A merchant refund of [merchant]'s amount to the card's account: a credit clearing, a
    new credit. *)
val refund_card
  :  t
  -> Card_core.Ids.Card_id.t
  -> Card_core.Merchant.t
  -> unit Or_error.t Deferred.t

(** A payee check answer for a beneficiary, published as a [Payee_check] event and
    returned by every later {!verify_payee} for it. *)
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
