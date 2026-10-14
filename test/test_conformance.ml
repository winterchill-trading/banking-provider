open! Core
open Async
open Banking_provider
open Helpers
module Suite = Conformance.Make (Fake_provider) (Fake_provider)

let print_results results =
  List.iter results ~f:(fun (name, result) ->
    match result with
    | Ok () -> printf "ok   %s\n" name
    | Error e -> printf "FAIL %s\n     %s\n" name (Error.to_string_hum e))
;;

let%expect_test "the fake passes the conformance suite" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let%map results = Suite.run_all (Conformance.Config.default ~run_id:"conf") fake in
    print_results results;
    [%expect
      {|
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
      |}])
;;

let%expect_test "with a fee and delayed settlement" =
  let config =
    { Fake_provider.Config.default with
      settlement = Delayed (Time_ns.Span.of_ms 1.)
    ; fee =
        (fun rail currency ->
          match rail with
          | Sepa_instant -> Some (Money.Fee.create ~fixed:(eur "0.25") currency |> ok_exn)
          | _ -> None)
    }
  in
  with_dir (fun dir ->
    (* Delayed work runs on the wall clock here, as against a real sandbox. *)
    let clock = Time_source.wall_clock () in
    let journal =
      Ledger.Journal.create ~time_source:clock ~fsync:false (dir ^/ "j") |> ok_exn
    in
    let fake = Fake_provider.create ~config ~time_source:clock ~journal () |> ok_exn in
    let%map results =
      Suite.run_all (Conformance.Config.default ~run_id:"conf-fee") fake
    in
    print_results results;
    Ledger.Journal.close journal;
    [%expect
      {|
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
      |}])
;;

let%expect_test "the fake passes the GBP conformance run" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let%map results = Suite.run_all (Conformance.Config.gbp ~run_id:"conf-gbp") fake in
    print_results results;
    [%expect
      {|
      ok   create_customer is idempotent on our customer id
      ok   a KYC approval is published as an event and reported by kyc_status
      ok   an approved customer gets a GBP account with a sort code and account number
      ok   a deposit is published once and credits the balance
      ok   a payment confirmed by SCA settles and debits amount plus fee
      ok   initiating the same transfer twice pays once
      ok   a payment above the balance does not leave the account
      ok   a wrong SCA code is refused without naming a factor
      ok   a webhook with a bad signature is refused
      ok   a test delivery arrives as a Ping event
      ok   a virtual card is approved, and declined with 57 once frozen
      ok   verify_payee answers, and a simulated answer is returned
      |}])
;;

let%expect_test "GBP with a Faster Payments fee and delayed settlement" =
  let gbp s = Money.Amount.of_decimal_string Money.Currency.gbp s |> ok_exn in
  let config =
    { Fake_provider.Config.default with
      settlement = Delayed (Time_ns.Span.of_ms 1.)
    ; fee =
        (fun rail currency ->
          match rail with
          | Faster_payments ->
            Some (Money.Fee.create ~fixed:(gbp "0.20") currency |> ok_exn)
          | _ -> None)
    }
  in
  with_dir (fun dir ->
    let clock = Time_source.wall_clock () in
    let journal =
      Ledger.Journal.create ~time_source:clock ~fsync:false (dir ^/ "j") |> ok_exn
    in
    let fake = Fake_provider.create ~config ~time_source:clock ~journal () |> ok_exn in
    let%map results =
      Suite.run_all (Conformance.Config.gbp ~run_id:"conf-gbp-fee") fake
    in
    print_results results;
    Ledger.Journal.close journal;
    [%expect
      {|
      ok   create_customer is idempotent on our customer id
      ok   a KYC approval is published as an event and reported by kyc_status
      ok   an approved customer gets a GBP account with a sort code and account number
      ok   a deposit is published once and credits the balance
      ok   a payment confirmed by SCA settles and debits amount plus fee
      ok   initiating the same transfer twice pays once
      ok   a payment above the balance does not leave the account
      ok   a wrong SCA code is refused without naming a factor
      ok   a webhook with a bad signature is refused
      ok   a test delivery arrives as a Ping event
      ok   a virtual card is approved, and declined with 57 once frozen
      ok   verify_payee answers, and a simulated answer is returned
      |}])
;;

let%expect_test "the fake passes the USD conformance run" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let%map results = Suite.run_all (Conformance.Config.usd ~run_id:"conf-usd") fake in
    print_results results;
    [%expect
      {|
      ok   create_customer is idempotent on our customer id
      ok   a KYC approval is published as an event and reported by kyc_status
      ok   an approved customer gets a USD account with a routing and account number
      ok   a deposit is published once and credits the balance
      ok   a payment confirmed by SCA settles and debits amount plus fee
      ok   initiating the same transfer twice pays once
      ok   a payment above the balance does not leave the account
      ok   a wrong SCA code is refused without naming a factor
      ok   a webhook with a bad signature is refused
      ok   a test delivery arrives as a Ping event
      ok   a virtual card is approved, and declined with 57 once frozen
      ok   verify_payee answers, and a simulated answer is returned
      |}])
;;
