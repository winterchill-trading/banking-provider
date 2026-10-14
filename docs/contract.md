# The provider contract

What an adapter for a real banking-as-a-service provider must do to implement
`Provider.S`, and what the fake taught us about it. The `.mli` files are the reference;
this page explains the choices.

## Calls

| Area | Calls | Notes for an adapter |
| --- | --- | --- |
| Customers | `create_customer`, `update_customer`, `kyc_status` | Send our `Kyc_core.Customer_id.t` as the provider's external id and look it up before creating, so a resend returns the same customer. |
| Verification | `start_verification`, `complete_verification` | E-mail and mobile are codes (`Code_sent`); document and liveness are the provider's hosted flow (`Hosted` with a `Sensitive.t` token); their result arrives as `Kyc` events. |
| Accounts | `open_account`, `accounts`, `balance`, `enrich_account`, `statement` | One account per customer and currency; `enrich_account` is idempotent and may return no address yet (some providers provision IBANs minutes after approval). A UK account's address is `Uk_account` (sort code and account number); give a GB IBAN too if the provider has one. A US account's is `Us_account` (routing number, account number, checking or savings). Details in a domestic format the other variants do not cover go in `Local { scheme; fields }`: Kyrgyz accounts as `kg` (`bank_code`, `account_number`), a Swiss QR-IBAN as `ch_qr_iban` (`qr_iban`) next to the account's `Iban`. The same account must keep the same details on every call. Balances are on the customer's side: available, held, posted. |
| Transfers | `quote_fee`, `initiate_transfer`, `transfer`, `cancel_transfer` | The draft's `Transfer.Id.t` is the provider idempotency key. The draft's `account` names our ledger account and is not sent. GBP payments are drafted on `Faster_payments`, `Chaps` or `Bacs` with `Uk_domestic` details; put the scheme's payment id in `scheme_ref` when it is known. USD payments go on `Ach { sec; same_day }`, `Rtp` or `Fedwire` with `Us_domestic` details (ACH trace number, RTP message id or Fedwire IMAD in `scheme_ref`). |
| Payee checks | `verify_payee` | Confirmation of Payee (UK) or Verification of Payee (SEPA) for a beneficiary, on behalf of the paying customer. Map the scheme's answers to `Match`, `Close_match` (with the name the bank holds), `No_match`, `Not_possible` (the bank cannot check this account), `Account_not_found` and `Unavailable` (time-out, outage: retryable). Return an error only when the request itself failed. Destinations no scheme checks answer `Not_possible`. Optionally also implement `Provider.Payee_details` (`verify_payee_details`): the same answer plus the receiving account's currency when the provider's response carries it (never guess one); otherwise `Provider.Payee_details_of_verify` gives callers the capability with no currency. |
| SCA | `confirm_sca` | One call for every challenge; the challenge's `purpose` says what resumes. |
| Swaps | `quote_swap`, `execute_swap` | The outcome is an event (`Swap_executed`, `Swap_failed`). |
| Cards | `issue_virtual_card`, `card`, `cards`, `set_card_status`, `set_card_limits`, `card_details_token` | `request_id` makes issuing idempotent. The card number is shown only through the provider's hosted component, after SCA. |
| Standing orders | `create_standing_order`, `cancel_standing_order` | Confirmed once by SCA; each run is a `Standing_order_run` event followed by the transfer's events. |
| Events | `events`, `ingest_webhook` | See below. |
| Sandbox | `simulate_deposit`, `simulate_kyc_decision`, `simulate_card_auth`, `simulate_transfer_outcome`, `simulate_payee_check`, `ping` | Map to the provider's simulator endpoints where they exist. `simulate_payee_check` fixes the answer for one beneficiary: publish it as a `Payee_check` event and return it from later `verify_payee` calls for that beneficiary (a provider whose simulator sets the next answer only can keep it per beneficiary in the adapter). |
| Simulation settings | `set_kyc_simulation`, `set_deposit_simulation` | How the sandbox answers on its own: KYC decided (`Approved`, `Pending_review`, `Rejected reason`) a delay after the last hosted step starts, deposits reported pending and settled or bounced a delay later; a default plus per-customer overrides. A provider without such switches answers `Sandbox.unsupported ~operation`; the conformance scenario for delayed KYC then checks nothing. |

## Events

- **Ids.** Every event carries the provider's own event (or delivery) id. It is the inbox
  key and, through `Event.booking_event_id`, part of every ledger idempotency key, so a
  redelivered webhook neither applies nor books twice. When a provider reuses one
  delivery id for several objects, the adapter must derive a stable id per object and
  event type.
- **At least once, any order.** `Transfer_update.apply` returns `Stale` for a report the
  transfer already passed (a `Pending` after `Settled`, the same status twice), so the
  adapter forwards everything and does not try to order events by time.
- **Signature first.** `ingest_webhook` checks the provider's signature over the raw
  body bytes in constant time (`Sensitive.constant_time_equal`), then parses. A bad
  signature publishes nothing. If the provider signs without a timestamp, replay
  protection is the inbox alone.
- **Normalization.** SEPA statuses become `Status_report` (pacs.002 codes) or the
  direct updates; every reject, return and recall carries an ISO 20022 reason from
  payments-core's `Iso_reason`. An SCT Inst payment with no answer after ten seconds is
  `Timed_out`, and a later settlement is still delivered (`Settled`). On-chain progress
  is `Confirmations` (the confirmation policy settles a deposit); a reorg is
  `Reorged`. Lightning settlement carries the preimage. Card messages use card-core's
  stable types: an authorization request or advice with the response code and who
  decided it, reversals, clearings (a credit clearing is a refund) and expiries.
- **Deposits** are `Incoming_transfer` with our id `Event.incoming_transfer_id
  ~provider_ref`, so later reports about the same deposit name the same transfer.
- **UK payments.** Faster Payments, CHAPS and Bacs statuses map to the direct updates
  (`Submitted`, `Pending`, `Settled`, `Rejected`, `Returned`); give rejects and returns a
  four-character ISO reason where the scheme has one. Deposits carry the rail, GBP and
  `Uk_domestic` details.
- **US payments.** ACH, RTP and Fedwire statuses map to the same direct updates; ACH
  returns carry the R-code's four-character reason as reported. RTP and Fedwire payments
  cannot be returned (payments-core refuses the transition).
- **Persisting events.** `Event.Stable.V1` cannot hold UK or US rails, accounts or details,
  or addresses on the newer networks
  (writing raises) and writes the newer payee check answers as `Not_possible`; an inbox
  or journal that may see GBP must use `Event.Stable.V2`. `Event.Stable.V2` cannot hold
  an account with a `Local` address; use `Event.Stable.V3` where one can occur (V2 bytes
  read as V3).
- **No personal data.** KYC events carry steps and status transitions only.

## Lessons from the fake

- **Book at the journal's time.** payments-core's `Booking` and card-core's `Booking`
  validate their entries against the balances with the time you pass as `recorded_at`.
  The ledger refuses a time before its last record and stamps records at least one
  nanosecond apart, so a synthetic clock that stands still makes the second booking in
  the same instant fail with "recorded_at goes backwards". Pass `Ledger.Journal.now`,
  not the clock. card-core's `Booking.settled` takes the time from the clearing's `at`,
  so stamp the clearing the same way.
- **Linked entries.** `Booking.post` books a transition's entries as one linked record;
  an empty list is an error there, so skip it.
- **Statements.** A ledger statement of the customer account alone shows holds as
  debits and never shows the capture (it leaves the pending sub-account). A bank
  statement merges the account with its pending sub-account and drops movements that
  net to zero.
- **Fees.** The provider's fee replaces the draft's: `initiate_transfer` books the fee
  the provider charges, and `quote_fee` gives it beforehand.
- **Details from the idempotency key.** The fake derives an account's IBAN, sort code,
  account numbers and deposit address from the key it opened the account with (our
  customer id and the currency by default), never from its own counters, so a restart
  with an empty memory gives the customer the same details. A provider does this by
  keeping the account; an adapter must look the account up by the key before opening.
- **Simulated timing runs on the injected clock.** Delayed KYC decisions and deposits
  are timers on the time source, independent of the settlement mode; a test advances a
  synthetic clock to see them, and the conformance suite (which waits on the wall clock)
  moves that clock along when it runs against the fake.
- **Overdrafts.** A payment whose hold fails is `Failed Insufficient_funds`, published
  under the event id the `Submitted` report would have had, so ids stay consecutive.

## Running conformance against a sandbox

```ocaml
module Suite = Banking_provider.Conformance.Make (My_provider) (My_provider)

let%expect_test "conformance against the sandbox" =
  match Sys.getenv "MY_PROVIDER_LIVE_TESTS" with
  | None -> print_endline "skipped: MY_PROVIDER_LIVE_TESTS is not set"; return ()
  | Some _ ->
    let config = Conformance.Config.default ~run_id:(Time_ns.to_string (Time_ns.now ())) in
    let%map results = Suite.run_all { config with timeout = Time_ns.Span.of_min 5. } provider in
    ...
```

Give the run a unique `run_id` (customer ids start with it), the sandbox's OTP as
`sca_code`, a payee IBAN the sandbox accepts and a timeout long enough for account
provisioning.

The suite runs in the config's currency over its rail. `Config.default` is EUR over SCT
Inst (accounts must show an IBAN); `Config.gbp ~run_id` is GBP over Faster Payments
(accounts must show a sort code and account number, or a GB IBAN), with a UK resident
and the payee `99-00-00 87654321`; `Config.usd ~run_id` is USD over standard ACH (PPD;
accounts must show a routing and account number), with a US resident and the payee
`123456780 000987654 checking`. Set `payee` to a destination the sandbox accepts for
the rail. A provider that holds only GBP runs `Config.gbp`, so the EUR-only scenarios
no longer fail on the currency:

```ocaml
let config = { (Conformance.Config.gbp ~run_id) with payee = Some "04-00-04 12345678" } in
Suite.run_all config provider
```

Two scenarios check the sandbox's own behaviour: an account opened and enriched again
keeps the same id and details, and a KYC approval set with `set_kyc_simulation` to wait
`kyc_delay` (200 ms by default) is not there at once and arrives within `timeout`.

The account scenario keeps its original name for EUR over SEPA and is named after the
currency and the address otherwise.
