open! Core
open Payments_core

let sha256 s = Cryptokit.hash_string (Cryptokit.Hash.sha256 ()) s

(* [n] decimal digits from the hash of [label] and [key]: one digit per hash byte,
   re-hashing for more than 32. Byte mod 10 is very slightly biased toward 0 to 5; a fake
   does not care. *)
let digits ~label ~key n =
  let buf = Buffer.create n in
  let rec fill seed =
    String.iter seed ~f:(fun c ->
      if Buffer.length buf < n
      then Buffer.add_char buf (Char.of_int_exn (48 + (Char.to_int c % 10))));
    if Buffer.length buf < n then fill (sha256 seed)
  in
  fill (sha256 (sprintf "fake-details:%s:%s" label key));
  Buffer.contents buf
;;

let iban_of ~country ~bban =
  Iban.of_string (country ^ Iban.check_digits ~country ~bban ^ bban)
;;

let eu_iban ?(country = "DE") ~key () =
  let open Or_error.Let_syntax in
  let country = String.uppercase country in
  let%bind length =
    Iban.length_for_country country
    |> Or_error.of_option ~error:(Error.create_s [%message "no IBAN length" country])
  in
  let bban =
    match country with
    | "DE" -> "50010517" ^ digits ~label:"de" ~key 10
    | _ -> digits ~label:("iban-" ^ country) ~key (length - 4)
  in
  iban_of ~country ~bban
;;

let uk_sort_code = Sort_code.of_string_exn "99-00-00"

let uk_modulus_rule =
  Uk_modulus.Rule.of_string "990000 990099 MOD11 0 0 0 0 0 0 8 7 6 5 4 3 2 1"
  |> Or_error.ok_exn
;;

let default_modulus = lazy (Uk_modulus.Table.create [ uk_modulus_rule ])

let uk_account ?modulus ?(sort_code = uk_sort_code) ~key () =
  let modulus =
    match modulus with
    | Some table -> table
    | None -> force default_modulus
  in
  let base = Int.of_string (digits ~label:"gb" ~key 8) in
  let number i = sprintf "%08d" ((base + i) % 100_000_000) in
  let passes account_number =
    match Uk_modulus.check modulus ~sort_code ~account_number with
    | Ok (Valid | Not_checked) -> true
    | Ok Invalid | Error _ -> false
  in
  (* MOD11 accepts about one number in eleven, so 100 candidates almost always hold one;
     some exception rules accept none, and then the hashed number stands. *)
  let account_number =
    List.init 100 ~f:number |> List.find ~f:passes |> Option.value ~default:(number 0)
  in
  Uk_account.create ~sort_code ~account_number () |> Or_error.ok_exn
;;

let us_routing = Aba.of_string_exn "123456780"

let us_account ?(routing = us_routing) ~key () =
  Us_account.create ~routing ~account_number:(digits ~label:"us" ~key 10) ()
  |> Or_error.ok_exn
;;

let kg_bank_code = "999001"

let kg ~key : Account.Address.t =
  Local
    { scheme = Account.Address.Local_scheme.kg
    ; fields =
        [ "bank_code", kg_bank_code
        ; "account_number", String.prefix kg_bank_code 3 ^ digits ~label:"kg" ~key 13
        ]
    }
;;

let ch_account ~key = digits ~label:"ch" ~key 12

let ch_iban ~key =
  iban_of ~country:"CH" ~bban:("08999" ^ ch_account ~key) |> Or_error.ok_exn
;;

let ch_qr_iban ~key =
  iban_of ~country:"CH" ~bban:("30999" ^ ch_account ~key) |> Or_error.ok_exn
;;

let ch ~key : Account.Address.t list =
  [ Iban { iban = ch_iban ~key; bic = None }
  ; Local
      { scheme = Account.Address.Local_scheme.ch_qr_iban
      ; fields = [ "qr_iban", Iban.to_string (ch_qr_iban ~key) ]
      }
  ]
;;

let for_currency currency ~key : Account.Address.t list Or_error.t =
  let open Or_error.Let_syntax in
  match Money.Currency.kind currency, Money.Currency.code currency with
  | Fiat, "EUR" ->
    let%map iban = eu_iban ~key () in
    [ Account.Address.Iban { iban; bic = None } ]
  | Fiat, "GBP" -> Ok [ Uk_account (uk_account ~key ()) ]
  | Fiat, "USD" -> Ok [ Us_account (us_account ~key ()) ]
  | Fiat, "CHF" -> Ok (ch ~key)
  | Fiat, "KGS" -> Ok [ kg ~key ]
  | _ ->
    Or_error.error_s
      [%message "no fake bank details for currency" (currency : Money.Currency.t)]
;;
