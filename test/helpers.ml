open! Core
open Async
open Banking_provider
module Time_source = Async_kernel.Time_source

let start = Time_ns.of_string_with_utc_offset "2026-10-13 09:00:00Z"
let eur s = Money.Amount.of_decimal_string Money.Currency.eur s |> ok_exn
let btc s = Money.Amount.of_decimal_string Money.Currency.btc s |> ok_exn

(* A synthetic person: no field is real. *)
let person =
  let open Kyc_core in
  { Person.given_name = Pii.create "Test"
  ; family_name = Pii.create "Customer"
  ; date_of_birth = Pii.create (Date.of_string "1990-01-01")
  ; nationality = Pii.create (Country.of_string "DE")
  ; residential_address =
      Pii.create
        { Address.line1 = "1 Test Street"
        ; line2 = None
        ; city = "Berlin"
        ; region = None
        ; postal_code = Some "10115"
        ; country = Country.of_string "DE"
        }
  ; email = Pii.create "customer@example.com"
  ; mobile = Pii.create "+4930000000"
  }
;;

let with_dir f =
  let dir = Filename_unix.temp_dir "banking-provider" "test" in
  Monitor.protect
    (fun () -> f dir)
    ~finally:(fun () ->
      let%map (_ : Core_unix.Exit_or_signal.t) =
        In_thread.run (fun () -> Core_unix.system (sprintf "rm -rf %s" (Filename.quote dir)))
      in
      ())
;;

(* A fake over a fresh journal and a synthetic clock at [start]. *)
let with_fake ?config f =
  with_dir (fun dir ->
    let clock = Time_source.create ~now:start () in
    let journal =
      Ledger.Journal.create
        ~time_source:(Time_source.read_only clock)
        ~fsync:false
        (dir ^/ "journal")
      |> ok_exn
    in
    let fake =
      Fake_provider.create ?config ~time_source:(Time_source.read_only clock) ~journal ()
      |> ok_exn
    in
    let%map result = f ~clock ~journal fake in
    Ledger.Journal.close journal;
    result)
;;

let code = Sensitive.of_string Fake_provider.sandbox_code
let ok d = Deferred.map d ~f:ok_exn

(* [let events = event_printer fake in ... events ()] prints the events published since
   the previous call, one per line. *)
let event_printer fake =
  let seen = ref 0 in
  fun () ->
    let all = Fake_provider.published fake in
    List.drop all !seen
    |> List.iter ~f:(fun (e : Event.t) ->
      print_s [%sexp (Event_id.to_string e.id : string), (e.kind : Event.Kind.t)]);
    seen := List.length all
;;

let print_balance fake account =
  let%map b = ok (Fake_provider.balance fake account) in
  print_s
    [%message
      ""
        ~available:(Money.Amount.to_string b.available)
        ~held:(Money.Amount.to_string b.held)
        ~posted:(Money.Amount.to_string b.posted)]
;;

(* A customer with approved KYC and an enriched account in [currency]. *)
let onboard ?(currency = Money.Currency.eur) ?(customer_id = "customer-1") fake =
  let%bind customer =
    ok
      (Fake_provider.create_customer
         fake
         ~customer_id:(Kyc_core.Customer_id.of_string customer_id)
         ~person)
  in
  let%bind () = ok (Fake_provider.simulate_kyc_decision fake customer.id Approve) in
  let%bind account = ok (Fake_provider.open_account fake customer.id currency) in
  let%map account = ok (Fake_provider.enrich_account fake account.id) in
  customer, account
;;
