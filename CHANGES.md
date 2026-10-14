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

### Compatibility

- The V2 formats were re-pinned once in this unreleased change set, when the US details
  and newer networks were added.
- `Event.Stable.V1` keeps its digest; the unversioned `bin_io` of `Account`,
  `Account.Address` and `Event.Kind` keeps its format. Writing UK or US rails, accounts or
  details, or newer-network addresses, in those formats raises; use V2.
- Every `Provider.S` and `Sandbox.S` implementation must add `verify_payee` and
  `simulate_payee_check`.
