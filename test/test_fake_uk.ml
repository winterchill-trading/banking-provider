open! Core
open Async
open Banking_provider
open Helpers
open Payments_core

let gbp s = Money.Amount.of_decimal_string Money.Currency.gbp s |> ok_exn

let uk_beneficiary ?(name = "Ada Example") ~id raw =
  Beneficiary.create
    ~id:(Beneficiary.Id.of_string id)
    ~owner:"customer-1"
    ~name
    ~rail:Faster_payments
    ~now:start
    raw
  |> ok_exn
;;

let%expect_test "a GBP account gets a sort code and account number" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let%map _customer, account = onboard ~currency:Money.Currency.gbp fake in
    print_s [%sexp (account.addresses : Account.Address.t list)];
    print_s
      [%sexp
        (Account.uk_account account |> Option.map ~f:Uk_account.to_string : string option)
        , (Account.iban account : Iban.t option)];
    [%expect
      {|
      ((Uk_account ((sort_code 990000) (account_number 68478747) (roll_number ()))))
      (("99-00-00 68478747") ())
      |}])
;;

let%expect_test "GBP deposits and payments on the UK rails" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let events = event_printer fake in
    let%bind _customer, account = onboard ~currency:Money.Currency.gbp fake in
    events ();
    let%bind (_ : Transfer.Id.t) =
      ok
        (Fake_provider.simulate_deposit
           fake
           ~account:account.id
           ~rail:Faster_payments
           (gbp "100.00"))
    in
    events ();
    let pay ~rail ~id amount =
      let draft =
        Transfer.draft
          ~id:(Transfer.Id.of_string id)
          ~rail
          ~account:(Ledger.Account_id.of_string "app:customer-1/gbp")
          ~beneficiary:(uk_beneficiary ~id:("ben-" ^ id) "04-00-04 12345678")
          ~amount
          ~reference:"rent"
          ~now:start
          ()
        |> ok_exn
      in
      let%bind started =
        ok (Fake_provider.initiate_transfer fake ~from:account.id draft)
      in
      let c = challenge_of started in
      let%map result = ok (Fake_provider.confirm_sca fake c.id ~code) in
      print_s [%sexp (result : Sca_challenge.Result.t)];
      events ()
    in
    let%bind () = pay ~rail:Faster_payments ~id:"fps-1" (gbp "30.00") in
    let%bind () = pay ~rail:Chaps ~id:"chaps-1" (gbp "20.00") in
    let%bind () = print_balance fake account.id in
    (* A deposit on a SEPA rail needs an IBAN, which a GBP account here does not have. *)
    let%map r =
      Fake_provider.simulate_deposit
        fake
        ~account:account.id
        ~rail:Sepa_credit
        (gbp "1.00")
    in
    print_s [%sexp (Result.is_error r : bool)];
    [%expect
      {|
      (evt_000001 (Kyc (customer cus_000001) (update (Status Submit))))
      (evt_000002 (Kyc (customer cus_000001) (update (Status Approve))))
      (evt_000003
       (Account_opened
        ((id acc_000001) (customer cus_000001) (currency GBP) (status Open)
         (addresses ()) (opened_at "2026-10-13 09:00:00Z"))))
      (evt_000004
       (Account_updated
        ((id acc_000001) (customer cus_000001) (currency GBP) (status Open)
         (addresses
          ((Uk_account
            ((sort_code 990000) (account_number 68478747) (roll_number ())))))
         (opened_at "2026-10-13 09:00:00Z"))))
      (evt_000005
       (Incoming_transfer (account acc_000001) (transfer in:dep_000001)
        (provider_ref dep_000001) (rail Faster_payments) (amount "100.00 GBP")
        (fee "0.00 GBP")
        (from (External (name "Sandbox Sender") (detail "99-00-00 12345678")))
        (reference "deposit dep_000001")
        (details (Uk_domestic ((scheme_ref (dep_000001)) (value_date ()))))
        (settled true)))
      Accepted
      (evt_000006
       (Transfer (transfer fps-1) (provider_ref tr_000001) (update Submitted)))
      (evt_000007
       (Transfer (transfer fps-1) (provider_ref tr_000001) (update Settled)))
      Accepted
      (evt_000008
       (Transfer (transfer chaps-1) (provider_ref tr_000002) (update Submitted)))
      (evt_000009
       (Transfer (transfer chaps-1) (provider_ref tr_000002) (update Pending)))
      (evt_000010
       (Transfer (transfer chaps-1) (provider_ref tr_000002) (update Settled)))
      ((available "50.00 GBP") (held "0.00 GBP") (posted "50.00 GBP"))
      true
      |}])
;;

let%expect_test "payee checks" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let%bind customer, _account = onboard ~currency:Money.Currency.gbp fake in
    let check ?name raw =
      let b = uk_beneficiary ?name ~id:("ben-" ^ raw) raw in
      let%map r = Fake_provider.verify_payee fake ~customer:customer.id b in
      print_s [%sexp (raw : string), (r : Beneficiary.Payee_check.t Or_error.t)]
    in
    let%bind () = check "04-00-04 12345678" in
    let%bind () = check "04-00-04 12345696" in
    let%bind () = check ~name:"Ada Lovelace Example" "04-00-04 12345697" in
    let%bind () = check "04-00-04 12345698" in
    let%bind () = check "04-00-04 12345699" in
    let%bind () = check "GB29 NWBK 6016 1331 9268 19" in
    (* A simulated answer wins, and is published. *)
    let events = event_printer fake in
    let b = uk_beneficiary ~id:"ben-fixed" "04-00-04 12345678" in
    let%bind () = ok (Fake_provider.simulate_payee_check fake b.id No_match) in
    events ();
    let%bind r = ok (Fake_provider.verify_payee fake ~customer:customer.id b) in
    print_s [%sexp (r : Beneficiary.Payee_check.t)];
    let%map unknown =
      Fake_provider.verify_payee fake ~customer:(Customer_ref.of_string "cus_999999") b
    in
    print_s [%sexp (Result.is_error unknown : bool)];
    [%expect
      {|
      ("04-00-04 12345678" (Ok Match))
      ("04-00-04 12345696" (Ok Unavailable))
      ("04-00-04 12345697" (Ok (Close_match (suggested_name "A L Example"))))
      ("04-00-04 12345698" (Ok No_match))
      ("04-00-04 12345699" (Ok Account_not_found))
      ("GB29 NWBK 6016 1331 9268 19" (Ok Match))
      (evt_000005 (Payee_check (beneficiary ben-fixed) (result No_match)))
      No_match
      true
      |}])
;;

let%expect_test "USD accounts and US payments" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let usd s = Money.Amount.of_decimal_string Money.Currency.usd s |> ok_exn in
    let%bind customer, account = onboard ~currency:Money.Currency.usd fake in
    print_s
      [%sexp
        (Account.us_account account |> Option.map ~f:Us_account.to_string : string option)];
    let events = event_printer fake in
    let%bind (_ : Transfer.Id.t) =
      ok
        (Fake_provider.simulate_deposit fake ~account:account.id ~rail:Rtp (usd "100.00"))
    in
    let beneficiary =
      Beneficiary.create
        ~id:(Beneficiary.Id.of_string "ben-us")
        ~owner:"customer-1"
        ~name:"Ada Example"
        ~rail:Rtp
        ~now:start
        "021000021 123456789"
      |> ok_exn
    in
    let draft =
      Transfer.draft
        ~id:(Transfer.Id.of_string "ach-1")
        ~rail:(Ach { sec = Ppd; same_day = true })
        ~account:(Ledger.Account_id.of_string "app:customer-1/usd")
        ~beneficiary
        ~amount:(usd "40.00")
        ~now:start
        ()
      |> ok_exn
    in
    let%bind started = ok (Fake_provider.initiate_transfer fake ~from:account.id draft) in
    let%bind (_ : Sca_challenge.Result.t) =
      ok (Fake_provider.confirm_sca fake (challenge_of started).id ~code)
    in
    events ();
    let%bind () = print_balance fake account.id in
    let%map check =
      ok (Fake_provider.verify_payee fake ~customer:customer.id beneficiary)
    in
    print_s [%sexp (check : Beneficiary.Payee_check.t)];
    [%expect
      {|
      ("123456780 9262868376 checking")
      (evt_000005
       (Incoming_transfer (account acc_000001) (transfer in:dep_000001)
        (provider_ref dep_000001) (rail Rtp) (amount "100.00 USD") (fee "0.00 USD")
        (from
         (External (name "Sandbox Sender")
          (detail "123456780 0000000001 checking")))
        (reference "deposit dep_000001")
        (details (Us_domestic ((scheme_ref (dep_000001)) (effective_date ()))))
        (settled true)))
      (evt_000006
       (Transfer (transfer ach-1) (provider_ref tr_000001) (update Submitted)))
      (evt_000007
       (Transfer (transfer ach-1) (provider_ref tr_000001) (update Pending)))
      (evt_000008
       (Transfer (transfer ach-1) (provider_ref tr_000001) (update Settled)))
      ((available "60.00 USD") (held "0.00 USD") (posted "60.00 USD"))
      Not_possible
      |}])
;;
