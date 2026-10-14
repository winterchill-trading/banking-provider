open! Core
open Async
open Banking_provider
open Helpers

let show (account : Account.t) =
  print_s
    [%message
      ""
        ~id:(Account_ref.to_string account.id : string)
        ~details:
          (List.concat_map account.addresses ~f:Account.Address.to_display_lines
           : string list)]
;;

let%expect_test "the same customer gets the same details after a restart" =
  let%bind first =
    with_fake (fun ~clock:_ ~journal:_ fake ->
      let%map _customer, account = onboard fake in
      account)
  in
  (* A fresh fake whose counters have moved on: the account id differs, the IBAN does not. *)
  let%map second =
    with_fake (fun ~clock:_ ~journal:_ fake ->
      let%bind (_ : Customer.t * Account.t) = onboard ~customer_id:"someone-else" fake in
      let%map _customer, account = onboard fake in
      account)
  in
  show first;
  show second;
  [%expect
    {|
    ((id acc_000001) (details ("IBAN DE38 5001 0517 5255 7208 29")))
    ((id acc_000002) (details ("IBAN DE38 5001 0517 5255 7208 29")))
    |}]
;;

let%expect_test "an explicit key opens further accounts in one currency" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let%bind customer, main = onboard fake in
    let open_with key currency =
      Fake_provider.open_account_with_key fake customer.id currency ~idempotency_key:key
    in
    let%bind savings = ok (open_with "savings-1" Money.Currency.eur) in
    let%bind again = ok (open_with "savings-1" Money.Currency.eur) in
    let%bind savings = ok (Fake_provider.enrich_account fake savings.id) in
    let%bind wrong = open_with "savings-1" Money.Currency.gbp in
    let%map plain = ok (Fake_provider.open_account fake customer.id Money.Currency.eur) in
    show main;
    show savings;
    print_s
      [%message
        ""
          ~same_key_same_account:(Account_ref.equal again.id savings.id : bool)
          ~open_account_keeps_the_first:(Account_ref.equal plain.id main.id : bool)
          ~other_currency:(Result.map wrong ~f:(fun a -> a.id) : Account_ref.t Or_error.t)];
    [%expect
      {|
      ((id acc_000001) (details ("IBAN DE38 5001 0517 5255 7208 29")))
      ((id acc_000002) (details ("IBAN DE79 5001 0517 3056 9758 89")))
      ((same_key_same_account true) (open_account_keeps_the_first true)
       (other_currency
        (Error
         ("idempotency key already opened another customer's or currency's account"
          savings-1))))
      |}])
;;

let%expect_test "CHF and KGS accounts" =
  let kgs = Money.Currency.register ~code:"KGS" ~exponent:2 ~kind:Fiat () |> ok_exn in
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let%bind _customer, chf = onboard ~currency:Money.Currency.chf fake in
    let%bind _customer, kg = onboard ~customer_id:"customer-2" ~currency:kgs fake in
    show chf;
    show kg;
    print_s
      [%sexp
        (Account.local kg ~scheme:Account.Address.Local_scheme.kg
         : (string * string) list option)];
    let%bind (_ : Payments_core.Transfer.Id.t) =
      ok
        (Fake_provider.simulate_deposit
           fake
           ~account:kg.id
           ~rail:Intraledger
           (Money.Amount.of_decimal_string kgs "500.00" |> ok_exn))
    in
    let%map () = print_balance fake kg.id in
    [%expect
      {|
      ((id acc_000001)
       (details
        ("IBAN CH85 0899 9342 5726 8532 0" "QR-IBAN CH30 3099 9342 5726 8532 0")))
      ((id acc_000002)
       (details ("Bank code 999001" "Account number 9990167727470402")))
      (((bank_code 999001) (account_number 9990167727470402)))
      ((available "500.00 KGS") (held "0.00 KGS") (posted "500.00 KGS"))
      |}])
;;
