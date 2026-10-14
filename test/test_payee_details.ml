open! Core
open Async
open Banking_provider
open Helpers
open Payments_core

let beneficiary ~rail ~id raw =
  Beneficiary.create
    ~id:(Beneficiary.Id.of_string id)
    ~owner:"customer-1"
    ~name:"Ada Example"
    ~rail
    ~now:start
    raw
  |> ok_exn
;;

let%expect_test "payee checks report the receiving account's currency when known" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let%bind customer, _ = onboard ~currency:Money.Currency.gbp fake in
    (* A EUR account held by the fake: paying its IBAN names a known account. *)
    let%bind _, eur_account =
      onboard ~customer_id:"customer-2" ~currency:Money.Currency.eur fake
    in
    let check (b : Beneficiary.t) =
      let%map r = Fake_provider.verify_payee_details fake ~customer:customer.id b in
      print_s [%sexp (b.id : Beneficiary.Id.t), (r : Payee_check_result.t Or_error.t)]
    in
    let own_iban = Account.iban eur_account |> Option.value_exn |> Iban.to_string in
    let%bind () = check (beneficiary ~rail:Sepa_credit ~id:"held-iban" own_iban) in
    let%bind () =
      check (beneficiary ~rail:Sepa_credit ~id:"other-iban" "DE89370400440532013000")
    in
    let%bind () =
      check (beneficiary ~rail:Faster_payments ~id:"uk" "04-00-04 12345698")
    in
    let%bind () = check (beneficiary ~rail:Fedwire ~id:"us" "021000021 123456789") in
    (* A fixed answer wins, including "unknown". *)
    let uk = beneficiary ~rail:Faster_payments ~id:"uk-fixed" "04-00-04 12345678" in
    Fake_provider.simulate_payee_account_currency fake uk.id (Some Money.Currency.eur);
    let%bind () = check uk in
    Fake_provider.simulate_payee_account_currency fake uk.id None;
    let%bind () = check uk in
    [%expect
      {|
      (held-iban (Ok ((result Match) (account_currency EUR))))
      (other-iban (Ok ((result Match))))
      (uk (Ok ((result No_match) (account_currency GBP))))
      (us (Ok ((result Not_possible) (account_currency USD))))
      (uk-fixed (Ok ((result Match) (account_currency EUR))))
      (uk-fixed (Ok ((result Match))))
      |}];
    return ())
;;

let%expect_test "any provider gets the capability without a currency" =
  let module D = Provider.Payee_details_of_verify (Fake_provider) in
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let%bind customer, _ = onboard ~currency:Money.Currency.gbp fake in
    let%map r =
      D.verify_payee_details
        fake
        ~customer:customer.id
        (beneficiary ~rail:Faster_payments ~id:"uk" "04-00-04 12345697")
    in
    print_s [%sexp (r : Payee_check_result.t Or_error.t)];
    [%expect {| (Ok ((result (Close_match (suggested_name "A Example"))))) |}])
;;

let%expect_test "stable digest and sexp" =
  print_endline [%bin_digest: Payee_check_result.Stable.V1.t];
  print_s
    [%sexp
      (Payee_check_result.create ~account_currency:Money.Currency.gbp Match
       : Payee_check_result.Stable.V1.t)];
  print_s [%sexp (Payee_check_result.create No_match : Payee_check_result.Stable.V1.t)];
  [%expect
    {|
    701002514b98c1669deefb5abe3f322b
    ((result Match) (account_currency GBP))
    ((result No_match))
    |}];
  return ()
;;
