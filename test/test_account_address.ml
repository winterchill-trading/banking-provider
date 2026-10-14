open! Core
open Banking_provider
open Payments_core

let kg : Account.Address.t =
  Local
    { scheme = "kg"
    ; fields = [ "bank_code", "999001"; "account_number", "9990010000004217" ]
    }
;;

let samples : Account.Address.t list =
  [ Iban
      { iban = Iban.of_string_exn "DE89370400440532013000"
      ; bic = Some (Bic.of_string_exn "COBADEFFXXX")
      }
  ; Crypto
      { address =
          Crypto_address.create_exn Ethereum "0x52908400098527886E0F7030069857D2E4169EE7"
      ; memo = None
      }
  ; Lightning_node { node_id = "02abcdef" }
  ; Uk_account
      (Uk_account.create
         ~sort_code:(Sort_code.of_string_exn "99-00-00")
         ~account_number:"12345678"
         ()
       |> ok_exn)
  ; Us_account
      (Us_account.create
         ~routing:(Aba.of_string_exn "123456780")
         ~account_number:"0000000001"
         ()
       |> ok_exn)
  ; kg
  ; Local { scheme = "ch_qr_iban"; fields = [ "qr_iban", "CH4431999123000889012" ] }
  ]
;;

(* Changing any of these digests is a version decision; V2 must stay as it was. *)
let%expect_test "Account.Address.Stable.V3 and Account.Stable.V3 shapes are pinned" =
  print_endline [%bin_digest: Account.Address.Stable.V2.t];
  print_endline [%bin_digest: Account.Address.Stable.V3.t];
  print_endline [%bin_digest: Account.Stable.V3.t];
  print_endline [%bin_digest: Event.Stable.V3.t];
  [%expect
    {|
    2518ee16746037db691391ae91f1d794
    26aab176c11fac64b33b63eda35cf53a
    3933c4fa7fd3359b7e20fef13f39550e
    8ffa364817e7338004aef9b02b0a8341
    |}]
;;

let%expect_test "V2 refuses a local address; V3 round-trips every address" =
  List.iter samples ~f:(fun address ->
    let v2 =
      Or_error.try_with (fun () ->
        Binable.to_string (module Account.Address.Stable.V2) address)
    in
    let v3 = Binable.to_string (module Account.Address.Stable.V3) address in
    let back = Binable.of_string (module Account.Address.Stable.V3) v3 in
    (* An address V2 can write has the same bytes in V3, so V3 reads old records. *)
    let same_bytes = Result.map v2 ~f:(String.equal v3) in
    print_s
      [%message
        ""
          ~round_trip:(Account.Address.equal address back : bool)
          (same_bytes : bool Or_error.t)]);
  [%expect
    {|
    ((round_trip true) (same_bytes (Ok true)))
    ((round_trip true) (same_bytes (Ok true)))
    ((round_trip true) (same_bytes (Ok true)))
    ((round_trip true) (same_bytes (Ok true)))
    ((round_trip true) (same_bytes (Ok true)))
    ((round_trip true)
     (same_bytes
      (Error
       ("Account.Address.Stable.V2 cannot hold local details; write V3" kg))))
    ((round_trip true)
     (same_bytes
      (Error
       ("Account.Address.Stable.V2 cannot hold local details; write V3"
        ch_qr_iban))))
    |}]
;;

let%expect_test "to_display_lines" =
  List.iter samples ~f:(fun address ->
    List.iter (Account.Address.to_display_lines address) ~f:print_endline;
    print_endline "--");
  [%expect
    {|
    IBAN DE89 3704 0044 0532 0130 00
    BIC COBADEFFXXX
    --
    Ethereum address 0x52908400098527886E0F7030069857D2E4169EE7
    --
    Lightning node 02abcdef
    --
    Sort code 99-00-00
    Account number 12345678
    --
    Routing number 123456780
    Account number 0000000001
    Checking account
    --
    Bank code 999001
    Account number 9990010000004217
    --
    QR-IBAN CH44 3199 9123 0008 8901 2
    --
    |}]
;;

let%expect_test "Account.local finds the fields of a scheme" =
  let account : Account.t =
    { id = Account_ref.of_string "acc_000001"
    ; customer = Customer_ref.of_string "cus_000001"
    ; currency = Money.Currency.eur
    ; status = Open
    ; addresses = samples
    ; opened_at = Time_ns.epoch
    }
  in
  print_s
    [%sexp
      (Account.local account ~scheme:"kg" : (string * string) list option)
      , (Account.local account ~scheme:"none" : (string * string) list option)];
  [%expect {| ((((bank_code 999001) (account_number 9990010000004217))) ()) |}]
;;
