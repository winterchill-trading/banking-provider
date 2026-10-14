open! Core
open Banking_provider
open Payments_core

let print_details currency ~key =
  Fake_details.for_currency currency ~key
  |> ok_exn
  |> List.iter ~f:(fun a ->
    List.iter (Account.Address.to_display_lines a) ~f:print_endline)
;;

let%expect_test "details per market for one key" =
  let kgs = Money.Currency.register ~code:"KGS" ~exponent:2 ~kind:Fiat () |> ok_exn in
  List.iter
    [ Money.Currency.eur
    ; Money.Currency.gbp
    ; Money.Currency.usd
    ; Money.Currency.chf
    ; kgs
    ]
    ~f:(fun currency ->
      printf "%s:\n" (Money.Currency.code currency);
      print_details currency ~key:"customer-1/acc-1");
  [%expect
    {|
    EUR:
    IBAN DE42 5001 0517 2050 0180 03
    GBP:
    Sort code 99-00-00
    Account number 77263464
    USD:
    Routing number 123456780
    Account number 4362144458
    Checking account
    CHF:
    IBAN CH04 0899 9810 6618 2249 9
    QR-IBAN CH46 3099 9810 6618 2249 9
    KGS:
    Bank code 999001
    Account number 9991783303643809
    |}];
  print_s
    [%sexp
      (Fake_details.for_currency Money.Currency.jpy ~key:"k"
       : Account.Address.t list Or_error.t)];
  [%expect {| (Error ("no fake bank details for currency" (currency JPY))) |}]
;;

let%expect_test "other EU countries" =
  List.iter [ "FR"; "NL"; "AT"; "XX" ] ~f:(fun country ->
    print_s [%sexp (Fake_details.eu_iban ~country ~key:"k" () : Iban.t Or_error.t)]);
  [%expect
    {|
    (Ok FR0250246253727389979919149)
    (Ok NL6551211538616825)
    (Ok AT102097321046850713)
    (Error ("no IBAN length" XX))
    |}]
;;

let key_gen = Base_quickcheck.Generator.string_non_empty

let%test_unit "same key, same details; the details are well formed" =
  Base_quickcheck.Test.run_exn
    (module struct
      type t = string [@@deriving sexp, quickcheck]

      let quickcheck_generator = key_gen
    end)
    ~f:(fun key ->
      List.iter
        [ Money.Currency.eur; Money.Currency.gbp; Money.Currency.usd; Money.Currency.chf ]
        ~f:(fun currency ->
          [%test_eq: Account.Address.t list]
            (Fake_details.for_currency currency ~key |> ok_exn)
            (Fake_details.for_currency currency ~key |> ok_exn));
      (* Each identifier parses back through its own validator. *)
      let iban = Fake_details.eu_iban ~key () |> ok_exn in
      [%test_eq: Iban.t] (Iban.of_string_exn (Iban.to_string iban)) iban;
      let ch = Fake_details.ch_iban ~key in
      let qr = Fake_details.ch_qr_iban ~key in
      [%test_eq: Iban.t] (Iban.of_string_exn (Iban.to_string ch)) ch;
      [%test_eq: Iban.t] (Iban.of_string_exn (Iban.to_string qr)) qr;
      let iid = Int.of_string (String.sub (Iban.bban qr) ~pos:0 ~len:5) in
      assert (iid >= 30000 && iid <= 31999);
      let us = Fake_details.us_account ~key () in
      [%test_eq: Aba.t] (Aba.of_string_exn (Aba.to_string us.routing)) us.routing)
;;

let%test_unit "UK account numbers pass the modulus check at the fake sort code" =
  let table = Uk_modulus.Table.create [ Fake_details.uk_modulus_rule ] in
  Base_quickcheck.Test.run_exn
    (module struct
      type t = string [@@deriving sexp, quickcheck]

      let quickcheck_generator = key_gen
    end)
    ~f:(fun key ->
      let a = Fake_details.uk_account ~key () in
      [%test_eq: Uk_modulus.Result.t]
        (Uk_modulus.check table ~sort_code:a.sort_code ~account_number:a.account_number
         |> ok_exn)
        Valid)
;;

let%expect_test "a caller's weight table and sort code" =
  (* A published-format line with standard MOD11 weights over a made-up range. *)
  let rule =
    Uk_modulus.Rule.of_string "990100 990199 MOD11 0 0 0 0 0 0 7 6 5 4 3 2 1 0" |> ok_exn
  in
  let table = Uk_modulus.Table.create [ rule ] in
  let sort_code = Sort_code.of_string_exn "99-01-00" in
  let a = Fake_details.uk_account ~modulus:table ~sort_code ~key:"k" () in
  print_s
    [%sexp
      (Uk_account.to_string a : string)
      , (Uk_modulus.check table ~sort_code ~account_number:a.account_number |> ok_exn
         : Uk_modulus.Result.t)];
  [%expect {| ("99-01-00 89844170" Valid) |}]
;;

let%expect_test "different keys give different details" =
  let numbers =
    List.init 1000 ~f:(fun i ->
      (Fake_details.us_account ~key:(sprintf "key-%d" i) ()).account_number)
  in
  print_s [%sexp (List.contains_dup numbers ~compare:String.compare : bool)];
  [%expect {| false |}]
;;
