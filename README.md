# banking-provider

The boundary between an application and a banking-as-a-service provider: the
`Provider.S` module type (customers and KYC, accounts, transfers, swaps, cards, standing
orders, webhooks), the normalized `Event.t` every provider reports in, a deterministic
`Fake_provider` that books into a [ledger](https://github.com/winterchill-trading/ledger)
journal, and a `Conformance` suite any implementation must pass.

## Why separate

An application should not know which provider moves its money. Putting the provider
contract in its own library, written only in the domain types of
[money](https://github.com/winterchill-trading/money),
[ledger](https://github.com/winterchill-trading/ledger),
[kyc-core](https://github.com/winterchill-trading/kyc-core),
[payments-core](https://github.com/winterchill-trading/payments-core) and
[card-core](https://github.com/winterchill-trading/card-core), means an adapter for a
real provider only translates its endpoints and webhooks, the application and its tests
run unchanged against the fake, and the same conformance scenarios check both. No
provider name, HTTP client or credential appears here.

## Quick start

```sh
dune build
dune test
dune exec banking-provider -- demo          # an offline journey on the fake
dune exec banking-provider -- conformance   # the suite against the fake
```

```
event evt_000001 Kyc
...
SCA challenge sca_000001, answering with the sandbox code
event evt_000007 Transfer
...
card authorization: 00
balance acc_000001: available 270.01 EUR, held 0.00 EUR
balance acc_000002: available 0.00166666 BTC, held 0.00000000 BTC
trial balance: balanced
```

There are no environment variables and no credentials: the fake is in-memory and an
adapter for a real provider reads its own configuration.

## Usage

```ocaml
open! Core
open Async
open Banking_provider

(* Any provider: the fake in tests and offline mode, an adapter in production. *)
module Consumer (P : Provider.S) = struct
  let run provider ~transfers =
    let inbox = Inbox.create () in
    Pipe.iter_without_pushback (P.events provider) ~f:(fun (event : Event.t) ->
      match Inbox.accept inbox event with
      | Error e -> Log.Global.error_s [%sexp (e : Error.t)]
      | Ok Duplicate -> () (* redelivered: already applied *)
      | Ok New ->
        (match event.kind with
         | Transfer { transfer; update; _ } ->
           Hashtbl.change transfers transfer ~f:(fun current ->
             Option.map current ~f:(fun t ->
               match Transfer_update.apply update t ~at:event.at () with
               | Ok (Changed t) -> t
               | Ok Stale | Error _ -> t))
         | _ -> ()))
  ;;
end
```

A webhook handler passes the raw request to `P.ingest_webhook`, which checks the
signature on the raw bytes before parsing and publishes the events to the same stream.
The application's durable inbox (keyed by `Event.id`) and its ledger bookings (keyed by
`Event.booking_event_id`) make a redelivery a no-op.

With the fake:

```ocaml
let journal = Ledger.Journal.create ~time_source ~fsync:false "provider.journal" |> ok_exn in
let fake = Fake_provider.create ~time_source ~journal () |> ok_exn in
let%bind customer = Fake_provider.create_customer fake ~customer_id ~person >>| ok_exn in
let%bind () = Fake_provider.simulate_kyc_decision fake customer.id Approve >>| ok_exn in
let%bind account = Fake_provider.open_account fake customer.id Money.Currency.eur >>| ok_exn in
let%bind (_ : Payments_core.Transfer.Id.t) =
  Fake_provider.simulate_deposit fake ~account:account.id ~rail:Sepa_instant amount
  >>| ok_exn
in
match%bind Fake_provider.initiate_transfer fake ~from:account.id draft >>| ok_exn with
| Challenge c ->
  Fake_provider.confirm_sca fake c.id ~code:(Sensitive.of_string Fake_provider.sandbox_code)
  >>| ok_exn
  >>| ignore
| Done _ -> return ()
```

## Modules

| Module | What it is |
| --- | --- |
| `Provider.S` | What an application needs from a provider, in Async with `Or_error` |
| `Sandbox.S` | Simulations a sandbox offers: deposit, KYC decision, card authorization, transfer outcome, ping |
| `Event` | The normalized event union with the provider's event id; `Stable.V1` with a pinned digest |
| `Transfer_update` | A provider's report about a transfer, and `apply` that treats redeliveries and overtaken reports as `Stale` |
| `Card_update` | Card status and scheme messages (request, advice, reversal, clearing, expiry) in card-core types |
| `Account`, `Customer`, `Card_info`, `Transfer_info`, `Statement` | Views a provider returns |
| `Sca_challenge` | A challenge the provider issues for an operation, and `Or_challenge` for calls that may need one |
| `Webhook` | Raw requests, HMAC-SHA256 helpers and a timestamped signature with a replay window |
| `Inbox` | In-memory dedup by event id (a service keeps the durable one in its own store) |
| `Sensitive` | Codes, tokens and secrets that print as `<redacted>`; constant-time equality |
| `Fake_provider` | Deterministic in-memory provider over a ledger journal |
| `Conformance` | Scenarios as a functor over `Provider.S` and `Sandbox.S` |
| `Customer_ref`, `Account_ref`, `Event_id`, `Standing_order_ref` | Provider-side ids |

## The contract

- **Idempotent creation.** `create_customer` (by our customer id), `initiate_transfer`
  (by the draft's transfer id), `issue_virtual_card` (by `request_id`) and
  `open_account` (one account per customer and currency) return what the first call
  made, so an outbox relay may resend them.
- **Results arrive as events,** at least once and in any order. The initiating response
  is never the final state. `transfer` and `kyc_status` serve reconciliation.
- **SCA belongs to the operation.** A transfer, swap, standing order or card-number
  reveal may answer `Challenge c`; `confirm_sca c.id ~code` resumes it. Wrong codes
  never name the factor; too many fail the operation.
- **Ids.** Our transfer, swap and standing order ids go out; provider ids
  (`Customer_ref`, `Account_ref`, card ids) come back. A deposit's transfer id is
  `Event.incoming_transfer_id ~provider_ref`, so every report about it lands on one
  transfer.
- **No personal data in events.** KYC events carry steps and status only; the
  application opens its kyc-core case with the person it collected
  (`Event.to_kyc_event`).
- **Statements show posted money**: hold placements and releases net out, captures
  appear as the payment.
- **Payee checks before paying.** `verify_payee ~customer beneficiary` answers `Match`,
  `Close_match` (with the name the bank holds), `No_match`, `Not_possible`,
  `Account_not_found` or `Unavailable` (UK Confirmation of Payee, SEPA Verification of
  Payee); a scheme outage is an answer, not an error.
- **UK accounts.** GBP accounts may carry `Account.Address.Uk_account` (sort code and
  account number) instead of an IBAN; `Account.uk_account` reads either.

See [docs/contract.md](docs/contract.md) for what an adapter must normalize and why.

## Fake provider

Deterministic: ids are counters (`cus_000001`, `acc_000001`, `evt_000001`, ...), time
comes from the injected `Time_source`, nothing is random. Every movement is booked in
the given `Ledger.Journal.t` with payments-core's `Booking` and `Swap` and card-core's
`Booking`, using the event id in the idempotency keys, so balances are what the journal
says and the trial balance always holds.

| Simulated | How |
| --- | --- |
| KYC: e-mail and mobile codes, hosted document and liveness, approve, reject, resubmission | `start_verification`, `complete_verification`, `simulate_kyc_decision` |
| IBAN, UK details and deposit addresses (valid DE IBANs, sort code 99-00-00 for GBP, Bech32, EIP-55, Tron, Solana) | `enrich_account`, or `auto_enrich` |
| SEPA, SCT Inst, Faster Payments, CHAPS, Bacs, on-chain (confirmations later), Lightning and internal deposits | `simulate_deposit` |
| Payments per rail: SEPA, CHAPS and Bacs `Pending` then `Settled`, SCT Inst and Faster Payments `Settled`, on-chain confirmations, Lightning preimage | settlement mode `Immediate`, `Delayed span` or `Manual` |
| Rejections, SCT Inst timeout and late settlement, returns, recalls, reorgs | `simulate_transfer_outcome` |
| Insufficient funds (`Failed Insufficient_funds`), SCA lockout (`Failed Sca_failed`) | automatic |
| Swaps at configured rates and spread, three linked ledger legs | `quote_swap`, `execute_swap` |
| Card decisions by card-core (`00`, `51`, `57`, `61`, `65`, ...), clearing (partial, above the auth), reversal, refund, stand-in advice, hold expiry | `simulate_card_auth`, `clear_card_auth`, `reverse_card_auth`, `refund_card`, `simulate_card_advice`, `expire_card_auths` |
| Payee checks: by the account number's last two digits (`96` unavailable, `97` close match, `98` no match, `99` not found, else match), or a fixed answer per beneficiary | `verify_payee`, `simulate_payee_check` |
| Standing orders, first run under the creation SCA, later runs exempt | `run_standing_orders` |
| Webhooks: every event kept as a signed delivery for redelivery and reordering | `webhook_deliveries`, `ingest_webhook` |

The fake keeps no personal data: `create_customer` and `update_customer` ignore the
person beyond accepting it.

## Conformance

`Conformance.Make (P) (S)` gives twelve scenarios, each awaiting results through
events or polling within a timeout, so a sandbox that provisions an IBAN minutes later
still passes: idempotent customers, KYC approval event, an account with the address
its rail needs, deposit event and balance, SCA-confirmed payment debiting amount plus
fee, resend pays once, overdraft refused, wrong code refused, unsigned webhook refused,
ping event, card approved and declined `57` when frozen, and a payee check that returns
a simulated answer. The currency and rail come from the config: `Config.default` is EUR
over SCT Inst, `Config.gbp` GBP over Faster Payments to a UK sort code. The fake passes
both in `test/` (immediately, and with fees and delayed settlement on the wall clock);
an adapter runs the same functor against its sandbox behind an environment gate.

## Stable formats

`Event.Stable.V1` (digest pinned in `test/test_event.ml`) is unchanged, and so is the
unversioned `bin_io` of `Account.t` and `Account.Address.t`. A UK rail, UK account or UK
transfer details cannot be written in those formats (it raises); persist events with
`Event.Stable.V2` and accounts with `Account.Stable.V2` wherever GBP can occur. V1 bytes
read as V2.

## Storage

This is a library: it persists nothing and does not depend on a database. The fake's
state is in memory and its money in the ledger journal file it is given. A service
that uses a provider keeps its own outbox, inbox and idempotency records in its own
store.

## Tests

`dune test` runs expect tests for onboarding, payments with SCA, resends, insufficient
funds, timeouts and late settlement, returns, stale and redelivered reports, SCA
lockout, delayed on-chain confirmations, swaps, card flows, standing orders, Lightning,
statements, webhook signatures and shuffled redelivery into the inbox, the pinned event
digest, the conformance suite, and a cram test of the CLI. Quickcheck properties: any
update applied twice is `Stale` the second time; random deposits, payments, card
authorizations and refunds keep the trial balance at zero, the account never overdrawn
and the statement's closing balance equal to the posted balance.

## Known gaps

- Lightning payments to a BOLT 11 invoice settle without a preimage in the fake: the
  invoice's payment hash belongs to the payee. Lightning addresses and LNURL get one.
- The fake charges cards only in their billing currency (no FX clearings) and does not
  simulate incremental authorizations or disputes, which card-core models.
- An approved stand-in advice above the available balance cannot be held (card-core
  places a hold for it) and returns an error; card-core books such a shortfall at
  clearing.
- Standing orders run when `run_standing_orders` is called, not on a timer.
- Provider-side KYC is steps and status only; risk, screening and EDD live in our
  kyc-core case.
