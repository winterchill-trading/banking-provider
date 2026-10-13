open! Core
open Async
open Banking_provider
open Helpers

let manual = { Fake_provider.Config.default with settlement = Manual }

let funded_payment ?(rail = Payments_core.Rail.Sepa_credit) fake ~id amount =
  let%bind _customer, account = onboard fake in
  let%bind (_ : Payments_core.Transfer.Id.t) =
    ok (Fake_provider.simulate_deposit fake ~account:account.id ~rail (eur "100.00"))
  in
  let draft = sepa_draft ~rail ~id account amount in
  let%bind started = ok (Fake_provider.initiate_transfer fake ~from:account.id draft) in
  let%map (_ : Sca_challenge.Result.t) =
    ok (Fake_provider.confirm_sca fake (challenge_of started).id ~code)
  in
  account, draft.id
;;

let outcome fake id update =
  let%bind () = ok (Fake_provider.simulate_transfer_outcome fake id update) in
  let%map info = ok (Fake_provider.transfer fake id) in
  print_s [%sexp (info.status : Payments_core.Transfer.Status.t)]
;;

let%expect_test "SCT Inst: timeout releases the hold, a late settlement debits again" =
  with_fake ~config:manual (fun ~clock:_ ~journal:_ fake ->
    let%bind account, id =
      funded_payment ~rail:Sepa_instant fake ~id:"inst-1" (eur "25.00")
    in
    let%bind () = print_balance fake account.id in
    let%bind () = outcome fake id Timed_out in
    let%bind () = print_balance fake account.id in
    let%bind () = outcome fake id Settled in
    let%bind () = print_balance fake account.id in
    [%expect
      {|
      ((available "75.00 EUR") (held "25.00 EUR") (posted "100.00 EUR"))
      Timed_out
      ((available "100.00 EUR") (held "0.00 EUR") (posted "100.00 EUR"))
      Settled
      ((available "75.00 EUR") (held "0.00 EUR") (posted "75.00 EUR"))
      |}];
    return ())
;;

let%expect_test "SEPA: a return after settlement credits the amount back" =
  with_fake ~config:manual (fun ~clock:_ ~journal:_ fake ->
    let%bind account, id = funded_payment fake ~id:"sct-1" (eur "40.00") in
    let%bind () = outcome fake id Settled in
    let%bind () = outcome fake id (Returned AC04) in
    let%bind () = print_balance fake account.id in
    [%expect
      {|
      Settled
      (Returned AC04)
      ((available "100.00 EUR") (held "0.00 EUR") (posted "100.00 EUR"))
      |}];
    return ())
;;

let%expect_test "redelivered and overtaken reports change nothing" =
  with_fake ~config:manual (fun ~clock:_ ~journal:_ fake ->
    let%bind account, id = funded_payment fake ~id:"sct-2" (eur "10.00") in
    let%bind () = outcome fake id Settled in
    (* A [Pending] that arrives after [Settled], and [Settled] twice. *)
    let%bind () = outcome fake id Pending in
    let%bind () = outcome fake id Settled in
    let%bind () = print_balance fake account.id in
    [%expect
      {|
      Settled
      Settled
      Settled
      ((available "90.00 EUR") (held "0.00 EUR") (posted "90.00 EUR"))
      |}];
    return ())
;;

let%expect_test "a rejection with an ISO reason releases the hold" =
  with_fake ~config:manual (fun ~clock:_ ~journal:_ fake ->
    let%bind account, id = funded_payment fake ~id:"sct-3" (eur "10.00") in
    let%bind () = outcome fake id (Rejected AC01) in
    let%bind () = print_balance fake account.id in
    [%expect
      {|
      (Rejected AC01)
      ((available "100.00 EUR") (held "0.00 EUR") (posted "100.00 EUR"))
      |}];
    return ())
;;

let%expect_test "three wrong codes fail the transfer" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let%bind _customer, account = onboard fake in
    let draft = sepa_draft ~id:"t-sca" account (eur "1.00") in
    let%bind started = ok (Fake_provider.initiate_transfer fake ~from:account.id draft) in
    let challenge = challenge_of started in
    let wrong = Sensitive.of_string "999999" in
    let%bind results =
      Deferred.List.init ~how:`Sequential 4 ~f:(fun _ ->
        ok (Fake_provider.confirm_sca fake challenge.id ~code:wrong))
    in
    print_s [%sexp (results : Sca_challenge.Result.t list)];
    let%bind info = ok (Fake_provider.transfer fake draft.id) in
    print_s [%sexp (info.status : Payments_core.Transfer.Status.t)];
    [%expect
      {|
      ((Wrong_code (attempts_left 2)) (Wrong_code (attempts_left 1))
       (Failed Too_many_attempts) (Failed Too_many_attempts))
      (Failed Sca_failed)
      |}];
    return ())
;;

let%expect_test "on-chain deposit: pending until confirmations arrive later" =
  let config =
    { Fake_provider.Config.default with
      settlement = Delayed (Time_ns.Span.of_min 10.)
    ; auto_enrich = true
    }
  in
  with_fake ~config (fun ~clock ~journal:_ fake ->
    let%bind _customer, account = onboard ~currency:Money.Currency.btc fake in
    print_s [%sexp (account.addresses : Account.Address.t list)];
    let events = event_printer fake in
    let%bind id =
      ok
        (Fake_provider.simulate_deposit
           fake
           ~account:account.id
           ~rail:(Onchain Bitcoin)
           (btc "0.01"))
    in
    let%bind () = print_balance fake account.id in
    let%bind () =
      Time_source.advance_by_alarms
        clock
        ~to_:(Time_ns.add start (Time_ns.Span.of_min 11.))
    in
    events ();
    let%bind () = print_balance fake account.id in
    let%bind info = ok (Fake_provider.transfer fake id) in
    print_s [%sexp (info.status : Payments_core.Transfer.Status.t)];
    [%expect
      {|
      ((Crypto
        (address
         ((network Bitcoin) (address bc1qngrfsa58rwnlg55md52ck3vhwth6k6lyv0a282)))
        (memo ())))
      ((available "0.00000000 BTC") (held "0.00000000 BTC")
       (posted "0.00000000 BTC"))
      (evt_000005
       (Incoming_transfer (account acc_000001) (transfer in:dep_000001)
        (provider_ref dep_000001) (rail (Onchain Bitcoin))
        (amount "0.01000000 BTC") (fee "0.00000000 BTC")
        (from (External (name "on-chain sender") (detail "")))
        (reference "deposit dep_000001")
        (details
         (Onchain (travel_rule ()) (tx_hash ()) (block_hash ()) (confirmations 0)
          (finalized false)))
        (settled false)))
      (evt_000006
       (Transfer (transfer in:dep_000001) (provider_ref dep_000001)
        (update
         (Confirmations
          (tx_hash
           42fbc2c48f53f05fdcc3a14d6fc9cd93997ef95882f0b664a1c64ab28e5ac0e9)
          (block_hash
           0adb17defd229be9b794c2fa8abab3bf0e0ebb3a78f8e684179f33515fc2d55b)
          (confirmations 6) (finalized true)))))
      ((available "0.01000000 BTC") (held "0.00000000 BTC")
       (posted "0.01000000 BTC"))
      Settled
      |}];
    return ())
;;
