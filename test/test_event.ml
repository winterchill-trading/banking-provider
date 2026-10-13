open! Core
open Async
open Banking_provider
open Helpers

(* Changing any type an event carries changes this digest. Persisted events (an inbox,
   a journal of provider events) would then no longer read back: add a [V2] instead. *)
let%expect_test "Event.Stable.V1 shape is pinned" =
  print_endline [%bin_digest: Event.Stable.V1.t];
  [%expect {| c2a5e9ee1ce7a62ad276c0c62abcf3f3 |}];
  return ()
;;

let%expect_test "events round-trip through sexp and bin_prot" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let%bind _customer, account = onboard fake in
    let%bind (_ : Payments_core.Transfer.Id.t) =
      ok (Fake_provider.simulate_deposit fake ~account:account.id ~rail:Sepa_credit (eur "1.00"))
    in
    let events = Fake_provider.published fake in
    let sexp_ok =
      List.for_all events ~f:(fun e -> Event.equal e (Event.t_of_sexp (Event.sexp_of_t e)))
    in
    let bin_ok =
      List.for_all events ~f:(fun e ->
        let s = Binable.to_string (module Event.Stable.V1) e in
        Event.equal e (Binable.of_string (module Event.Stable.V1) s))
    in
    print_s [%message "" ~events:(List.length events : int) (sexp_ok : bool) (bin_ok : bool)];
    [%expect {| ((events 5) (sexp_ok true) (bin_ok true)) |}];
    return ())
;;

let%expect_test "KYC events become kyc-core events keyed by the provider event id" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let%bind customer =
      ok
        (Fake_provider.create_customer
           fake
           ~customer_id:(Kyc_core.Customer_id.of_string "customer-9")
           ~person)
    in
    let%bind (_ : Customer.Verification_session.t) =
      ok (Fake_provider.start_verification fake customer.id Email)
    in
    let%bind state = ok (Fake_provider.complete_verification fake customer.id Email ~code) in
    print_s [%sexp (state : Kyc_core.Verification.State.t)];
    (* The application opens the case itself, with the person it collected; provider
       events carry no personal data. *)
    let opened : Kyc_core.Event.t =
      { id = Kyc_core.Event_id.of_string "app-open-1"
      ; customer_id = customer.customer_id
      ; at = start
      ; actor = System
      ; note = None
      ; kind = Opened person
      }
    in
    let case =
      List.filter_map (Fake_provider.published fake) ~f:(fun e ->
        Event.to_kyc_event e ~customer_id:customer.customer_id ~provider:"fake")
      |> List.cons opened
      |> Kyc_core.Kyc_case.of_events customer.customer_id
      |> ok_exn
    in
    print_s
      [%sexp
        (Kyc_core.Kyc_case.step case Email : Kyc_core.Verification.State.t)
        , (Kyc_core.Kyc_case.has_applied case (Kyc_core.Event_id.of_string "evt_000002")
           : bool)];
    [%expect {|
      (Verified "2026-10-13 09:00:00Z")
      ((Verified "2026-10-13 09:00:00Z") true)
      |}];
    return ())
;;

let%expect_test "statement lines follow the balance" =
  with_fake (fun ~clock ~journal:_ fake ->
    let%bind _customer, account = onboard fake in
    let%bind (_ : Payments_core.Transfer.Id.t) =
      ok (Fake_provider.simulate_deposit fake ~account:account.id ~rail:Sepa_instant (eur "80.00"))
    in
    Time_source.advance_directly clock ~to_:(Time_ns.add start (Time_ns.Span.of_hr 1.));
    let draft = sepa_draft ~rail:Sepa_instant ~id:"st-1" account (eur "30.00") in
    let%bind started = ok (Fake_provider.initiate_transfer fake ~from:account.id draft) in
    let%bind (_ : Sca_challenge.Result.t) =
      ok (Fake_provider.confirm_sca fake (challenge_of started).id ~code)
    in
    let%bind statement =
      ok
        (Fake_provider.statement
           fake
           account.id
           ~from:start
           ~until:(Time_ns.add start (Time_ns.Span.of_day 1.)))
    in
    print_s [%sexp (statement : Statement.t)];
    print_s [%sexp (Statement.check statement : unit Or_error.t)];
    [%expect {|
      ((account acc_000001) (currency EUR) (from "2026-10-13 09:00:00Z")
       (until "2026-10-14 09:00:00Z") (opening "0.00 EUR")
       (lines
        (((at "2026-10-13 09:00:00Z") (amount "80.00 EUR") (code DEPOSIT)
          (reference in:dep_000001) (balance "80.00 EUR"))
         ((at "2026-10-13 10:00:00.000000001Z") (amount "-30.00 EUR")
          (code CAPTURE) (reference st-1) (balance "50.00 EUR"))))
       (closing "50.00 EUR"))
      (Ok ())
      |}];
    return ())
;;

let%expect_test "Lightning: a payment to an address settles with a preimage" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let%bind _customer, account = onboard ~currency:Money.Currency.btc_lightning fake in
    let sats s = Money.Amount.of_decimal_string Money.Currency.btc_lightning s |> ok_exn in
    let%bind (_ : Payments_core.Transfer.Id.t) =
      ok (Fake_provider.simulate_deposit fake ~account:account.id ~rail:Lightning (sats "0.001"))
    in
    let beneficiary =
      Payments_core.Beneficiary.create
        ~id:(Payments_core.Beneficiary.Id.of_string "ln-payee")
        ~owner:"customer-1"
        ~name:"Payee"
        ~rail:Lightning
        ~now:start
        "payee@example.com"
      |> ok_exn
    in
    let draft =
      Payments_core.Transfer.draft
        ~id:(Payments_core.Transfer.Id.of_string "ln-1")
        ~rail:Lightning
        ~account:(Ledger.Account_id.of_string "app:customer-1/btc-ln")
        ~beneficiary
        ~amount:(sats "0.0004")
        ~now:start
        ()
      |> ok_exn
    in
    let%bind started = ok (Fake_provider.initiate_transfer fake ~from:account.id draft) in
    let%bind (_ : Sca_challenge.Result.t) =
      ok (Fake_provider.confirm_sca fake (challenge_of started).id ~code)
    in
    let%bind info = ok (Fake_provider.transfer fake draft.id) in
    print_s
      [%sexp
        (info.status : Payments_core.Transfer.Status.t)
        , (info.details : Payments_core.Transfer.Details.t)];
    let%bind () = print_balance fake account.id in
    [%expect {|
      (Settled
       (Lightning
        (payment_hash
         (26685900ae36bf638e0db4a748e62a32bd171c5f404ce4d538576d2eb8d3419e))
        (preimage
         (40477774b089fa547552a3374a8c7e90175d8871a009dd046f5d70199ee6d904))))
      ((available "0.00060000000 BTC@lightning")
       (held "0.00000000000 BTC@lightning") (posted "0.00060000000 BTC@lightning"))
      |}];
    return ())
;;
