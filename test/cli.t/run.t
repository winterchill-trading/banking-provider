The demo journey runs offline against the fake provider; ids are counters, so the
output is the same on every run.

  $ banking-provider demo
  event evt_000001 Kyc
  event evt_000002 Kyc
  event evt_000003 Account_opened
  event evt_000004 Account_updated
  event evt_000005 Account_opened
  event evt_000006 Incoming_transfer
  SCA challenge sca_000001, answering with the sandbox code
  event evt_000007 Transfer
  event evt_000008 Transfer
  SCA challenge sca_000002, answering with the sandbox code
  event evt_000009 Swap_executed
  event evt_000010 Card
  event evt_000011 Card
  event evt_000012 Card
  card authorization: 00
  balance acc_000001: available 270.01 EUR, held 0.00 EUR
  balance acc_000002: available 0.00166666 BTC, held 0.00000000 BTC
  trial balance: balanced

The fake passes the conformance suite:

  $ banking-provider conformance
  ok   create_customer is idempotent on our customer id
  ok   a KYC approval is published as an event and reported by kyc_status
  ok   an approved customer gets an EUR account with an IBAN
  ok   a deposit is published once and credits the balance
  ok   a payment confirmed by SCA settles and debits amount plus fee
  ok   initiating the same transfer twice pays once
  ok   a payment above the balance does not leave the account
  ok   a wrong SCA code is refused without naming a factor
  ok   a webhook with a bad signature is refused
  ok   a test delivery arrives as a Ping event
  ok   a virtual card is approved, and declined with 57 once frozen
  ok   verify_payee answers, and a simulated answer is returned
