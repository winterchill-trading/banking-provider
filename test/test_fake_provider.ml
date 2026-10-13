open! Core
open Async
open Banking_provider
open Helpers

let%expect_test "onboarding: KYC events, an account and an IBAN" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let events = event_printer fake in
    let%bind customer, account = onboard fake in
    events ();
    [%expect
      {|
      (evt_000001 (Kyc (customer cus_000001) (update (Status Submit))))
      (evt_000002 (Kyc (customer cus_000001) (update (Status Approve))))
      (evt_000003
       (Account_opened
        ((id acc_000001) (customer cus_000001) (currency EUR) (status Open)
         (addresses ()) (opened_at "2026-10-13 09:00:00Z"))))
      (evt_000004
       (Account_updated
        ((id acc_000001) (customer cus_000001) (currency EUR) (status Open)
         (addresses ((Iban (iban DE97500105170000000001) (bic ()))))
         (opened_at "2026-10-13 09:00:00Z"))))
      |}];
    let%bind status = ok (Fake_provider.kyc_status fake customer.id) in
    print_s [%sexp (status.status : Kyc_core.Status.t), (status.tier : Kyc_core.Tier.t)];
    print_s [%sexp (account.addresses : Account.Address.t list)];
    [%expect
      {|
      (Approved T0)
      ((Iban (iban DE97500105170000000001) (bic ())))
      |}];
    return ())
;;

let%expect_test "SEPA deposit, then a payment confirmed by SCA" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let%bind _customer, account = onboard fake in
    let events = event_printer fake in
    let%bind (_ : Payments_core.Transfer.Id.t) =
      ok
        (Fake_provider.simulate_deposit
           fake
           ~account:account.id
           ~rail:Sepa_credit
           (eur "100.00"))
    in
    events ();
    let%bind () = print_balance fake account.id in
    [%expect
      {|
      (evt_000005
       (Incoming_transfer (account acc_000001) (transfer in:dep_000001)
        (provider_ref dep_000001) (rail Sepa_credit) (amount "100.00 EUR")
        (fee "0.00 EUR")
        (from (External (name "Sandbox Sender") (detail DE89370400440532013000)))
        (reference "deposit dep_000001")
        (details
         (Sepa
          ((payment_id
            ((end_to_end_id dep-000001) (instruction_id ()) (uetr ()) (tx_id ())
             (msg_id ()) (pmt_inf_id ())))
           (debtor
            ((name "Sandbox Sender") (iban DE89370400440532013000) (bic ())
             (address ())))
           (creditor
            ((name "Account Holder") (iban DE97500105170000000001) (bic ())
             (address ())))
           (remittance None_given) (charge_bearer SLEV) (purpose ())
           (requested_execution_date ()) (acceptance_time ()) (value_date ())
           (booking_date ()) (last_status ()))))
        (settled true)))
      ((available "100.00 EUR") (held "0.00 EUR") (posted "100.00 EUR"))
      |}];
    let draft = sepa_draft ~id:"t-1" account (eur "30.00") in
    let%bind started = ok (Fake_provider.initiate_transfer fake ~from:account.id draft) in
    let challenge = challenge_of started in
    print_s [%sexp (challenge : Sca_challenge.t)];
    [%expect
      {|
      ((id sca_000001) (purpose (Transfer t-1)) (factors (Otp))
       (expires_at "2026-10-13 09:05:00Z") (attempts_left 3))
      |}];
    (* A wrong code first: one attempt fewer, nothing moves. *)
    let%bind wrong =
      ok
        (Fake_provider.confirm_sca fake challenge.id ~code:(Sensitive.of_string "000000"))
    in
    let%bind right = ok (Fake_provider.confirm_sca fake challenge.id ~code) in
    print_s [%sexp (wrong : Sca_challenge.Result.t), (right : Sca_challenge.Result.t)];
    events ();
    let%bind () = print_balance fake account.id in
    let%bind info = ok (Fake_provider.transfer fake draft.id) in
    print_s [%sexp (info.status : Payments_core.Transfer.Status.t)];
    print_s [%sexp (Fake_provider.background_errors fake : Error.t list)];
    [%expect
      {|
      ((Wrong_code (attempts_left 2)) Accepted)
      (evt_000006
       (Transfer (transfer t-1) (provider_ref tr_000001) (update Submitted)))
      (evt_000007
       (Transfer (transfer t-1) (provider_ref tr_000001) (update Pending)))
      (evt_000008
       (Transfer (transfer t-1) (provider_ref tr_000001) (update Settled)))
      ((available "70.00 EUR") (held "0.00 EUR") (posted "70.00 EUR"))
      Settled
      ()
      |}];
    return ())
;;

let%expect_test "a resent initiation returns the same transfer" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let%bind _customer, account = onboard fake in
    let%bind (_ : Payments_core.Transfer.Id.t) =
      ok
        (Fake_provider.simulate_deposit
           fake
           ~account:account.id
           ~rail:Sepa_instant
           (eur "50.00"))
    in
    let draft = sepa_draft ~rail:Sepa_instant ~id:"t-2" account (eur "10.00") in
    let%bind first = ok (Fake_provider.initiate_transfer fake ~from:account.id draft) in
    let%bind again = ok (Fake_provider.initiate_transfer fake ~from:account.id draft) in
    print_s [%sexp (Sca_challenge.equal (challenge_of first) (challenge_of again) : bool)];
    let%bind (_ : Sca_challenge.Result.t) =
      ok (Fake_provider.confirm_sca fake (challenge_of first).id ~code)
    in
    let%bind after = ok (Fake_provider.initiate_transfer fake ~from:account.id draft) in
    (match after with
     | Done info -> print_s [%sexp (info.status : Payments_core.Transfer.Status.t)]
     | Challenge _ -> print_endline "challenge again");
    let%bind () = print_balance fake account.id in
    [%expect
      {|
      true
      Settled
      ((available "40.00 EUR") (held "0.00 EUR") (posted "40.00 EUR"))
      |}];
    return ())
;;

let%expect_test "a payment above the available balance fails and holds nothing" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let%bind _customer, account = onboard fake in
    let events = event_printer fake in
    let draft = sepa_draft ~id:"t-3" account (eur "10.00") in
    let%bind started = ok (Fake_provider.initiate_transfer fake ~from:account.id draft) in
    let%bind (_ : Sca_challenge.Result.t) =
      ok (Fake_provider.confirm_sca fake (challenge_of started).id ~code)
    in
    events ();
    let%bind () = print_balance fake account.id in
    [%expect
      {|
      (evt_000005
       (Transfer (transfer t-3) (provider_ref tr_000001)
        (update (Failed Insufficient_funds))))
      ((available "0.00 EUR") (held "0.00 EUR") (posted "0.00 EUR"))
      |}];
    return ())
;;
