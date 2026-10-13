open! Core
open Async
open Banking_provider
open Helpers

let%expect_test "swap EUR to BTC after SCA books three legs" =
  with_fake (fun ~clock:_ ~journal fake ->
    let%bind customer, eur_account = onboard fake in
    let%bind btc_account = ok (Fake_provider.open_account fake customer.id Money.Currency.btc) in
    let%bind (_ : Payments_core.Transfer.Id.t) =
      ok (Fake_provider.simulate_deposit fake ~account:eur_account.id ~rail:Sepa_instant (eur "600.00"))
    in
    let events = event_printer fake in
    let%bind quote =
      ok (Fake_provider.quote_swap fake ~from:eur_account.id ~to_:btc_account.id ~sell:(eur "300.00"))
    in
    print_s
      [%message
        ""
          ~sell:(Money.Amount.to_string quote.sell)
          ~buy:(Money.Amount.to_string quote.buy)];
    let%bind started = ok (Fake_provider.execute_swap fake quote.id) in
    let%bind result = ok (Fake_provider.confirm_sca fake (challenge_of started).id ~code) in
    print_s [%sexp (result : Sca_challenge.Result.t)];
    events ();
    let%bind () = print_balance fake eur_account.id in
    let%bind () = print_balance fake btc_account.id in
    Ledger.Trial_balance.of_balances (Ledger.Journal.balances journal)
    |> Ledger.Trial_balance.check
    |> ok_exn;
    [%expect {|
      ((sell "300.00 EUR") (buy "0.00500000 BTC"))
      Accepted
      (evt_000007
       (Swap_executed (swap swp_000001) (sell "300.00 EUR") (fee "0.00 EUR")
        (buy "0.00500000 BTC")))
      ((available "300.00 EUR") (held "0.00 EUR") (posted "300.00 EUR"))
      ((available "0.00500000 BTC") (held "0.00000000 BTC")
       (posted "0.00500000 BTC"))
      |}];
    return ())
;;

let%expect_test "card: approve, decline, clear, refund" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let%bind customer, account = onboard fake in
    let%bind (_ : Payments_core.Transfer.Id.t) =
      ok (Fake_provider.simulate_deposit fake ~account:account.id ~rail:Sepa_instant (eur "50.00"))
    in
    let%bind card =
      ok (Fake_provider.issue_virtual_card fake ~request_id:"card-req-1" customer.id ~account:account.id)
    in
    let%bind again =
      ok (Fake_provider.issue_virtual_card fake ~request_id:"card-req-1" customer.id ~account:account.id)
    in
    print_s
      [%message
        ""
          ~same:(Card_info.equal card again : bool)
          ~pan:(Option.map card.masked_pan ~f:Card_core.Masked_pan.to_string : string option)
          ~status:(card.status : Card_core.Card.Status.t)];
    let events = event_printer fake in
    let%bind approved =
      ok (Fake_provider.simulate_card_auth fake card.id ~amount:(eur "12.50") ~merchant:(merchant "Grocer"))
    in
    let%bind too_much =
      ok (Fake_provider.simulate_card_auth fake card.id ~amount:(eur "60.00") ~merchant:(merchant "Grocer"))
    in
    let%bind (_ : Card_info.t) = ok (Fake_provider.set_card_status fake card.id Frozen) in
    let%bind frozen =
      ok (Fake_provider.simulate_card_auth fake card.id ~amount:(eur "1.00") ~merchant:(merchant "Grocer"))
    in
    print_s
      [%sexp
        (approved : Card_core.Response_code.t)
        , (too_much : Card_core.Response_code.t)
        , (frozen : Card_core.Response_code.t)];
    let%bind () =
      ok (Fake_provider.refund_card fake card.id ~amount:(eur "2.50") ~merchant:(merchant "Grocer"))
    in
    events ();
    let%bind () = print_balance fake account.id in
    [%expect {|
      ((same true) (pan ("**** 0001 10/29")) (status Active))
      (00 51 57)
      (evt_000007
       (Card (card card_000001)
        (update
         (Auth_request
          ((auth auth_000001) (network_txn ntx_000001) (amount "12.50 EUR")
           (merchant_amount "12.50 EUR")
           (merchant ((name Grocer) (mcc 5411) (country DE)))
           (entry_mode Ecommerce) (response 00) (decided_by Provider_default))))))
      (evt_000008
       (Card (card card_000001)
        (update
         (Clearing (clearing clr_000001) (auth (auth_000001))
          (network_txn ntx_000001) (amount "12.50 EUR")
          (merchant_amount "12.50 EUR")
          (merchant ((name Grocer) (mcc 5411) (country DE)))))))
      (evt_000009
       (Card (card card_000001)
        (update
         (Auth_request
          ((auth auth_000002) (network_txn ntx_000002) (amount "60.00 EUR")
           (merchant_amount "60.00 EUR")
           (merchant ((name Grocer) (mcc 5411) (country DE)))
           (entry_mode Ecommerce) (response 51) (decided_by Provider_default))))))
      (evt_000010 (Card (card card_000001) (update (Status_changed Frozen))))
      (evt_000011
       (Card (card card_000001)
        (update
         (Auth_request
          ((auth auth_000003) (network_txn ntx_000003) (amount "1.00 EUR")
           (merchant_amount "1.00 EUR")
           (merchant ((name Grocer) (mcc 5411) (country DE)))
           (entry_mode Ecommerce) (response 57) (decided_by Provider_default))))))
      (evt_000012
       (Card (card card_000001)
        (update
         (Refund (clearing clr_000002) (network_txn ()) (amount "2.50 EUR")
          (merchant ((name Grocer) (mcc 5411) (country DE)))))))
      ((available "40.00 EUR") (held "0.00 EUR") (posted "40.00 EUR"))
      |}];
    return ())
;;

let%expect_test "card clearing: partial, above the authorization, reversal" =
  let config = { Fake_provider.Config.default with settlement = Manual } in
  with_fake ~config (fun ~clock:_ ~journal:_ fake ->
    let%bind customer, account = onboard fake in
    let%bind (_ : Payments_core.Transfer.Id.t) =
      ok (Fake_provider.simulate_deposit fake ~account:account.id ~rail:Sepa_instant (eur "100.00"))
    in
    let%bind card =
      ok (Fake_provider.issue_virtual_card fake ~request_id:"r" customer.id ~account:account.id)
    in
    let auth_ids = ref [] in
    let%bind () =
      Deferred.List.iter ~how:`Sequential [ "20.00"; "30.00"; "10.00" ] ~f:(fun amount ->
        let%map (_ : Card_core.Response_code.t) =
          ok (Fake_provider.simulate_card_auth fake card.id ~amount:(eur amount) ~merchant:(merchant ~mcc:5812 "Diner"))
        in
        ())
    in
    List.iter (Fake_provider.published fake) ~f:(fun e ->
      match e.kind with
      | Card { update = Auth_request a; _ } -> auth_ids := a.auth :: !auth_ids
      | _ -> ());
    let a1, a2, a3 =
      match List.rev !auth_ids with
      | [ a; b; c ] -> a, b, c
      | _ -> assert false
    in
    let%bind () = print_balance fake account.id in
    let%bind () = ok (Fake_provider.clear_card_auth fake a1 ~amount:(eur "15.00") ()) in
    let%bind () = ok (Fake_provider.clear_card_auth fake a2 ~amount:(eur "33.00") ()) in
    let%bind () = ok (Fake_provider.reverse_card_auth fake a3 ()) in
    let%bind () = print_balance fake account.id in
    [%expect {|
      ((available "40.00 EUR") (held "60.00 EUR") (posted "100.00 EUR"))
      ((available "52.00 EUR") (held "0.00 EUR") (posted "52.00 EUR"))
      |}];
    return ())
;;

let%expect_test "card details need SCA, then a token that never prints" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let%bind customer, account = onboard fake in
    let%bind card =
      ok (Fake_provider.issue_virtual_card fake ~request_id:"r" customer.id ~account:account.id)
    in
    let%bind first = ok (Fake_provider.card_details_token fake card.id) in
    let%bind (_ : Sca_challenge.Result.t) =
      ok (Fake_provider.confirm_sca fake (challenge_of first).id ~code)
    in
    let%bind second = ok (Fake_provider.card_details_token fake card.id) in
    print_s [%sexp (second : Card_core.Pan_display_token.t Sca_challenge.Or_challenge.t)];
    [%expect {| (Done <pan-display-token>) |}];
    return ())
;;

let%expect_test "standing order: confirmed once, runs on its dates" =
  with_fake (fun ~clock ~journal:_ fake ->
    let%bind _customer, account = onboard fake in
    let%bind (_ : Payments_core.Transfer.Id.t) =
      ok (Fake_provider.simulate_deposit fake ~account:account.id ~rail:Sepa_instant (eur "100.00"))
    in
    let draft = sepa_draft ~id:"template" account (eur "20.00") in
    let beneficiary =
      match draft.counterparty with
      | Beneficiary b -> b
      | External _ -> assert false
    in
    let order =
      Payments_core.Standing_order.create
        ~id:(Payments_core.Standing_order.Id.of_string "so-rent")
        ~account:(Ledger.Account_id.of_string "app:customer-1/eur")
        ~beneficiary
        ~rail:Sepa_credit
        ~amount:(eur "20.00")
        ~details:draft.details
        ~schedule:(Monthly { day = 14 })
        ~start:(Date.of_string "2026-10-14")
        ()
      |> ok_exn
    in
    let%bind started = ok (Fake_provider.create_standing_order fake ~from:account.id order) in
    let%bind (_ : Sca_challenge.Result.t) =
      ok (Fake_provider.confirm_sca fake (challenge_of started).id ~code)
    in
    let%bind before = ok (Fake_provider.run_standing_orders fake) in
    Time_source.advance_directly clock ~to_:(Time_ns.add start (Time_ns.Span.of_day 1.));
    let%bind first = ok (Fake_provider.run_standing_orders fake) in
    let%bind repeat = ok (Fake_provider.run_standing_orders fake) in
    Time_source.advance_directly clock ~to_:(Time_ns.add start (Time_ns.Span.of_day 32.));
    let%bind second = ok (Fake_provider.run_standing_orders fake) in
    print_s
      [%sexp
        (before : Payments_core.Transfer.Id.t list)
        , (first : Payments_core.Transfer.Id.t list)
        , (repeat : Payments_core.Transfer.Id.t list)
        , (second : Payments_core.Transfer.Id.t list)];
    let%bind () = print_balance fake account.id in
    [%expect {|
      (() (so-rent:2026-10-14) () (so-rent:2026-11-14))
      ((available "60.00 EUR") (held "0.00 EUR") (posted "60.00 EUR"))
      |}];
    return ())
;;
