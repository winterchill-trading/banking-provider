open! Core
open Async
open Banking_provider
open Helpers

let advance clock span = Time_source.advance_by_alarms_by clock span

let status fake customer =
  let%map kyc = ok (Fake_provider.kyc_status fake customer) in
  print_s [%sexp (kyc.status : Kyc_core.Status.t)]
;;

let new_customer fake id =
  ok
    (Fake_provider.create_customer
       fake
       ~customer_id:(Kyc_core.Customer_id.of_string id)
       ~person)
;;

let start fake (customer : Customer.t) step =
  let%map (_ : Customer.Verification_session.t) =
    ok (Fake_provider.start_verification fake customer.id step)
  in
  ()
;;

let%expect_test "a delayed approval comes the delay after the last hosted step" =
  with_fake (fun ~clock ~journal:_ fake ->
    let events = event_printer fake in
    let%bind () =
      ok
        (Fake_provider.set_kyc_simulation
           fake
           (Decide { outcome = Approved; delay = Time_ns.Span.of_min 5. }))
    in
    let%bind customer = new_customer fake "customer-1" in
    let%bind () = start fake customer Identity_document in
    let%bind () = advance clock (Time_ns.Span.of_min 4.) in
    let%bind () = status fake customer.id in
    [%expect {| Created |}];
    (* A second hosted step restarts the wait. *)
    let%bind () = start fake customer Liveness in
    let%bind () = advance clock (Time_ns.Span.of_min 4.) in
    let%bind () = status fake customer.id in
    [%expect {| Created |}];
    let%bind () = advance clock (Time_ns.Span.of_min 1.) in
    let%map () = status fake customer.id in
    events ();
    print_s [%sexp (Fake_provider.background_errors fake : Error.t list)];
    [%expect
      {|
      Approved
      (evt_000001
       (Kyc (customer cus_000001)
        (update (Step (step Identity_document) (state Sent)))))
      (evt_000002
       (Kyc (customer cus_000001) (update (Step (step Liveness) (state Sent)))))
      (evt_000003
       (Kyc (customer cus_000001)
        (update
         (Step (step Identity_document) (state (Verified "2026-10-13 09:09:00Z"))))))
      (evt_000004
       (Kyc (customer cus_000001)
        (update (Step (step Liveness) (state (Verified "2026-10-13 09:09:00Z"))))))
      (evt_000005 (Kyc (customer cus_000001) (update (Status Submit))))
      (evt_000006 (Kyc (customer cus_000001) (update (Status Approve))))
      ()
      |}])
;;

let%expect_test "a per-customer override wins over the default" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let%bind () =
      ok
        (Fake_provider.set_kyc_simulation
           fake
           (Decide { outcome = Rejected "document unreadable"; delay = Time_ns.Span.zero }))
    in
    let%bind a = new_customer fake "customer-a" in
    let%bind b = new_customer fake "customer-b" in
    let%bind () =
      ok
        (Fake_provider.set_kyc_simulation
           fake
           ~customer:b.id
           (Decide { outcome = Pending_review; delay = Time_ns.Span.zero }))
    in
    print_s
      [%sexp
        (Fake_provider.kyc_simulation fake ~customer:a.id () : Sandbox.Kyc_simulation.t)
        , (Fake_provider.kyc_simulation fake ~customer:b.id () : Sandbox.Kyc_simulation.t)];
    [%expect
      {|
      ((Decide (outcome (Rejected "document unreadable")) (delay 0s))
       (Decide (outcome Pending_review) (delay 0s)))
      |}];
    let%bind () = start fake a Identity_document in
    let%bind () = start fake b Identity_document in
    let%bind () = status fake a.id in
    let%bind () = status fake b.id in
    [%expect {|
      (Rejected "document unreadable")
      Verifying
      |}];
    (* In review, the case waits for a decision by hand. *)
    let%bind () = ok (Fake_provider.simulate_kyc_decision fake b.id Approve) in
    let%map () = status fake b.id in
    [%expect {| Approved |}])
;;

let%expect_test "a decision by hand before the delay is not overturned" =
  with_fake (fun ~clock ~journal:_ fake ->
    let%bind () =
      ok
        (Fake_provider.set_kyc_simulation
           fake
           (Decide { outcome = Approved; delay = Time_ns.Span.of_min 1. }))
    in
    let%bind customer = new_customer fake "customer-1" in
    let%bind () = start fake customer Identity_document in
    let%bind () =
      ok (Fake_provider.simulate_kyc_decision fake customer.id (Reject "by hand"))
    in
    let%bind () = advance clock (Time_ns.Span.of_min 2.) in
    let%map () = status fake customer.id in
    print_s [%sexp (Fake_provider.background_errors fake : Error.t list)];
    [%expect {|
      (Rejected "by hand")
      ()
      |}])
;;

let%expect_test "a delayed deposit is pending, then credited" =
  with_fake (fun ~clock ~journal:_ fake ->
    let%bind _customer, account = onboard fake in
    let events = event_printer fake in
    let%bind () =
      ok
        (Fake_provider.set_deposit_simulation
           fake
           { delay = Time_ns.Span.of_min 1.; outcome = Credit })
    in
    let%bind id =
      ok
        (Fake_provider.simulate_deposit
           fake
           ~account:account.id
           ~rail:Sepa_instant
           (eur "25.00"))
    in
    let%bind () = print_balance fake account.id in
    let%bind info = ok (Fake_provider.transfer fake id) in
    print_s [%sexp (info.status : Payments_core.Transfer.Status.t)];
    [%expect
      {|
      ((available "0.00 EUR") (held "0.00 EUR") (posted "0.00 EUR"))
      Pending
      |}];
    let%bind () = advance clock (Time_ns.Span.of_min 1.) in
    let%map () = print_balance fake account.id in
    events ();
    [%expect
      {|
      ((available "25.00 EUR") (held "0.00 EUR") (posted "25.00 EUR"))
      (evt_000005
       (Incoming_transfer (account acc_000001) (transfer in:dep_000001)
        (provider_ref dep_000001) (rail Sepa_instant) (amount "25.00 EUR")
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
            ((name "Account Holder") (iban DE38500105175255720829) (bic ())
             (address ())))
           (remittance None_given) (charge_bearer SLEV) (purpose ())
           (requested_execution_date ()) (acceptance_time ()) (value_date ())
           (booking_date ()) (last_status ()))))
        (settled false)))
      (evt_000006
       (Transfer (transfer in:dep_000001) (provider_ref dep_000001)
        (update Settled)))
      |}])
;;

let%expect_test "a bounced deposit is rejected and never credited" =
  with_fake (fun ~clock ~journal:_ fake ->
    let%bind _customer, account = onboard fake in
    let%bind other, other_account = onboard ~customer_id:"customer-2" fake in
    let events = event_printer fake in
    let%bind () =
      ok
        (Fake_provider.set_deposit_simulation
           fake
           ~customer:other.id
           { delay = Time_ns.Span.of_sec 30.; outcome = Bounce AC04 })
    in
    let deposit (account : Account.t) =
      ok
        (Fake_provider.simulate_deposit
           fake
           ~account:account.id
           ~rail:Sepa_credit
           (eur "10.00"))
    in
    let%bind (_ : Payments_core.Transfer.Id.t) = deposit account in
    let%bind (_ : Payments_core.Transfer.Id.t) = deposit other_account in
    let%bind () = advance clock (Time_ns.Span.of_sec 30.) in
    let%bind () = print_balance fake account.id in
    let%map () = print_balance fake other_account.id in
    events ();
    print_s [%sexp (Fake_provider.background_errors fake : Error.t list)];
    [%expect
      {|
      ((available "10.00 EUR") (held "0.00 EUR") (posted "10.00 EUR"))
      ((available "0.00 EUR") (held "0.00 EUR") (posted "0.00 EUR"))
      (evt_000009
       (Incoming_transfer (account acc_000001) (transfer in:dep_000001)
        (provider_ref dep_000001) (rail Sepa_credit) (amount "10.00 EUR")
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
            ((name "Account Holder") (iban DE38500105175255720829) (bic ())
             (address ())))
           (remittance None_given) (charge_bearer SLEV) (purpose ())
           (requested_execution_date ()) (acceptance_time ()) (value_date ())
           (booking_date ()) (last_status ()))))
        (settled true)))
      (evt_000010
       (Incoming_transfer (account acc_000002) (transfer in:dep_000002)
        (provider_ref dep_000002) (rail Sepa_credit) (amount "10.00 EUR")
        (fee "0.00 EUR")
        (from (External (name "Sandbox Sender") (detail DE89370400440532013000)))
        (reference "deposit dep_000002")
        (details
         (Sepa
          ((payment_id
            ((end_to_end_id dep-000002) (instruction_id ()) (uetr ()) (tx_id ())
             (msg_id ()) (pmt_inf_id ())))
           (debtor
            ((name "Sandbox Sender") (iban DE89370400440532013000) (bic ())
             (address ())))
           (creditor
            ((name "Account Holder") (iban DE52500105170913001186) (bic ())
             (address ())))
           (remittance None_given) (charge_bearer SLEV) (purpose ())
           (requested_execution_date ()) (acceptance_time ()) (value_date ())
           (booking_date ()) (last_status ()))))
        (settled false)))
      (evt_000011
       (Transfer (transfer in:dep_000002) (provider_ref dep_000002)
        (update (Rejected AC04))))
      ()
      |}])
;;
