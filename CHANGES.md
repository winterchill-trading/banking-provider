# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- `Account.Address.Uk_account` (sort code and account number) and `Account.uk_account`,
  which also reads a GB IBAN.
- `Provider.S.verify_payee`: a payee-name check (UK Confirmation of Payee, SEPA
  Verification of Payee) returning `Payments_core.Beneficiary.Payee_check.t`.
- `Sandbox.S.simulate_payee_check`, with the fake's existing signature: the answer is
  published and returned by later `verify_payee` calls for the beneficiary.
- Fake provider: GBP accounts with UK details (sort code 99-00-00), deposits and payments
  on Faster Payments, CHAPS and Bacs, deterministic payee checks.
- `Conformance.Config` gains `currency`, `rail` and `payee` (defaults EUR, SCT Inst,
  `payee_iban`) and `Config.gbp` (GBP over Faster Payments); a twelfth scenario checks
  `verify_payee` against a simulated answer.
- `Account.Address.Us_account` (routing and account number, type) and
  `Account.us_account`; the fake opens USD accounts (routing number 123456780) and moves
  ACH, RTP and Fedwire payments; `Conformance.Config.usd` (USD over ACH PPD).
- Crypto addresses on Base, Arbitrum, Plasma and Spark in `Account.Address.Stable.V2`.
- `Event.Stable.V2`, `Event.Kind.Stable`, `Account.Stable.V1`/`V2` and
  `Account.Address.Stable.V1`/`V2`, with pinned digests.
- `Account.Address.Local { scheme; fields }` for domestic formats the other variants do
  not cover (a bank code and account number in Kyrgyzstan, a QR-IBAN next to a Swiss
  IBAN), `Account.Address.Local_scheme` (`kg`, `ch_qr_iban`), `Account.local`, and
  `Account.Address.to_display_lines` for every variant.
- `Account.Address.Stable.V3`, `Account.Stable.V3`, `Event.Kind.Stable.V3` and
  `Event.Stable.V3`, which can hold `Local` addresses, with pinned digests.
- `Fake_details`: deterministic bank details from a key, per market: EU IBANs with valid
  check digits, a GB sort code and account number that pass the modulus check, a US
  account at a routing number with a valid check digit, a KG bank code and account
  number, a CH IBAN with its QR-IBAN.
- Fake provider: account details and crypto addresses derive from the open-account
  idempotency key (our customer id and the currency, or the key given to the new
  `open_account_with_key`), so a restarted fake gives a customer the same IBAN; a new
  key opens a further account in the same currency. CHF and KGS accounts.
- `Sandbox.S.set_kyc_simulation` and `set_deposit_simulation` (with `Kyc_outcome`,
  `Kyc_simulation`, `Deposit_outcome`, `Deposit_simulation`): KYC decided as approved,
  pending review or rejected a delay after the last hosted step, deposits delayed or
  bounced, each with a default and per-customer overrides. `Sandbox.unsupported` and
  `Sandbox.is_unsupported` for sandboxes without such controls. The fake implements both
  and reports the settings in force (`kyc_simulation`, `deposit_simulation`).
- Conformance: `Config.kyc_delay` (200 ms) and two scenarios, an account keeps its details
  when opened and enriched again, and a KYC decision set to wait arrives after its delay
  (skipped by a sandbox that answers `unsupported`).

### Compatibility

- The V2 formats were re-pinned once in this unreleased change set, when the US details
  and newer networks were added.
- `Event.Stable.V1` keeps its digest; the unversioned `bin_io` of `Account`,
  `Account.Address` and `Event.Kind` keeps its format. Writing UK or US rails, accounts or
  details, or newer-network addresses, in those formats raises; use V2.
- Every `Provider.S` and `Sandbox.S` implementation must add `verify_payee` and
  `simulate_payee_check`, and every `Sandbox.S` implementation `set_kyc_simulation` and
  `set_deposit_simulation` (`Sandbox.unsupported` is a valid answer).
- `Account.Address.Stable.V2`, `Account.Stable.V2` and `Event.Stable.V2` keep their
  digests; writing a `Local` address in them raises, so persist with V3 where one can
  occur. V2 bytes read as V3. A match on `Account.Address.t` needs a `Local` case.
- The fake's IBANs, UK and US account numbers and crypto addresses change: they no
  longer follow the account counter. Expect tests that pin them need re-promoting.
