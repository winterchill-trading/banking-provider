# The provider contract

What an adapter for a real banking-as-a-service provider must do to implement
`Provider.S`, and what the fake taught us about it. The `.mli` files are the reference;
this page explains the choices.

## Calls

| Area | Calls | Notes for an adapter |
| --- | --- | --- |
| Customers | `create_customer`, `update_customer`, `kyc_status` | Send our `Kyc_core.Customer_id.t` as the provider's external id and look it up before creating, so a resend returns the same customer. |
| Verification | `start_verification`, `complete_verification` | E-mail and mobile are codes (`Code_sent`); document and liveness are the provider's hosted flow (`Hosted` with a `Sensitive.t` token); their result arrives as `Kyc` events. |
| Accounts | `open_account`, `accounts`, `balance`, `enrich_account`, `statement` | One account per customer and currency; `enrich_account` is idempotent and may return no address yet (some providers provision IBANs minutes after approval). A UK account's address is `Uk_account` (sort code and account number); give a GB IBAN too if the provider has one. Balances are on the customer's side: available, held, posted. |
| Transfers | `quote_fee`, `initiate_transfer`, `transfer`, `cancel_transfer` | The draft's `Transfer.Id.t` is the provider idempotency key. The draft's `account` names our ledger account and is not sent. GBP payments are drafted on `Faster_payments`, `Chaps` or `Bacs` with `Uk_domestic` details; put the scheme's payment id in `scheme_ref` when it is known. |
| Payee checks | `verify_payee` | Confirmation of Payee (UK) or Verification of Payee (SEPA) for a beneficiary, on behalf of the paying customer. Map the scheme's answers to `Match`, `Close_match` (with the name the bank holds), `No_match`, `Not_possible` (the bank cannot check this account), `Account_not_found` and `Unavailable` (time-out, outage: retryable). Return an error only when the request itself failed. Destinations no scheme checks answer `Not_possible`. |
| SCA | `confirm_sca` | One call for every challenge; the challenge's `purpose` says what resumes. |
| Swaps | `quote_swap`, `execute_swap` | The outcome is an event (`Swap_executed`, `Swap_failed`). |
| Cards | `issue_virtual_card`, `card`, `cards`, `set_card_status`, `set_card_limits`, `card_details_token` | `request_id` makes issuing idempotent. The card number is shown only through the provider's hosted component, after SCA. |
| Standing orders | `create_standing_order`, `cancel_standing_order` | Confirmed once by SCA; each run is a `Standing_order_run` event followed by the transfer's events. |
| Events | `events`, `ingest_webhook` | See below. |
| Sandbox | `simulate_deposit`, `simulate_kyc_decision`, `simulate_card_auth`, `simulate_transfer_outcome`, `simulate_payee_check`, `ping` | Map to the provider's simulator endpoints where they exist. `simulate_payee_check` fixes the answer for one beneficiary: publish it as a `Payee_check` event and return it from later `verify_payee` calls for that beneficiary (a provider whose simulator sets the next answer only can keep it per beneficiary in the adapter). |

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
- **Persisting events.** `Event.Stable.V1` cannot hold UK rails, accounts or details
  (writing raises) and writes the newer payee check answers as `Not_possible`; an inbox
  or journal that may see GBP must use `Event.Stable.V2`.
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
and the payee `99-00-00 87654321`. Set `payee` to a destination the sandbox accepts for
the rail. A provider that holds only GBP runs `Config.gbp`, so the EUR-only scenarios
no longer fail on the currency:

```ocaml
let config = { (Conformance.Config.gbp ~run_id) with payee = Some "04-00-04 12345678" } in
Suite.run_all config provider
```

The account scenario keeps its original name for EUR over SEPA and is named after the
currency and the address otherwise.
