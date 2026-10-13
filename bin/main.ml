(* banking-provider: run the fake provider offline.

   demo         onboarding, a deposit, a payment with SCA, a swap and a card purchase,
                printing every event and the final balances
   conformance  the conformance suite against the fake *)

open! Core
open Async
open Banking_provider
open Payments_core

let ok d = Deferred.map d ~f:Or_error.ok_exn
let eur s = Money.Amount.of_decimal_string Money.Currency.eur s |> Or_error.ok_exn
let code = Sensitive.of_string Fake_provider.sandbox_code

let with_journal journal_path f =
  let path, cleanup =
    match journal_path with
    | Some p -> p, fun () -> ()
    | None ->
      let dir = Filename_unix.temp_dir "banking-provider" "demo" in
      ( dir ^/ "journal"
      , fun () ->
          ignore (Core_unix.system (sprintf "rm -rf %s" (Filename.quote dir)) : _) )
  in
  let journal = Ledger.Journal.create ~fsync:false path |> Or_error.ok_exn in
  let%map result = Monitor.protect (fun () -> f journal) ~finally:(fun () -> return ()) in
  Ledger.Journal.close journal;
  cleanup ();
  result
;;

let confirm fake = function
  | Sca_challenge.Or_challenge.Done _ -> return ()
  | Challenge (c : Sca_challenge.t) ->
    printf "SCA challenge %s, answering with the sandbox code\n" (Sca.Id.to_string c.id);
    let%map (_ : Sca_challenge.Result.t) = ok (Fake_provider.confirm_sca fake c.id ~code) in
    ()
;;

let demo journal_path =
  with_journal journal_path (fun journal ->
    let fake =
      Fake_provider.create ~time_source:(Time_source.wall_clock ()) ~journal ()
      |> Or_error.ok_exn
    in
    let events = Fake_provider.events fake in
    don't_wait_for
      (Pipe.iter_without_pushback events ~f:(fun (e : Event.t) ->
         printf "event %s %s\n" (Event_id.to_string e.id) (Event.Kind.name e.kind)));
    let person = (Conformance.Config.default ~run_id:"demo").person in
    let%bind customer =
      ok
        (Fake_provider.create_customer
           fake
           ~customer_id:(Kyc_core.Customer_id.of_string "demo-customer")
           ~person)
    in
    let%bind () = ok (Fake_provider.simulate_kyc_decision fake customer.id Approve) in
    let%bind account = ok (Fake_provider.open_account fake customer.id Money.Currency.eur) in
    let%bind account = ok (Fake_provider.enrich_account fake account.id) in
    let%bind btc = ok (Fake_provider.open_account fake customer.id Money.Currency.btc) in
    let%bind (_ : Transfer.Id.t) =
      ok (Fake_provider.simulate_deposit fake ~account:account.id ~rail:Sepa_instant (eur "500.00"))
    in
    let iban = Option.value_exn (Account.iban account) in
    let payee = "FR1420041010050500013M02606" in
    let beneficiary =
      Beneficiary.create
        ~id:(Beneficiary.Id.of_string "demo-payee")
        ~owner:"demo-customer"
        ~name:"Payee"
        ~rail:Sepa_instant
        ~now:(Time_ns.now ())
        payee
      |> Or_error.ok_exn
    in
    let party name iban = { Iso20022.Party.name; iban; bic = None; address = None } in
    let draft =
      Transfer.draft
        ~id:(Transfer.Id.of_string "demo-payment-1")
        ~rail:Sepa_instant
        ~account:(Ledger.Account_id.of_string "app:demo-customer/eur")
        ~beneficiary
        ~amount:(eur "120.00")
        ~details:
          (Sepa
             (Sepa.Details.create
                ~payment_id:
                  (Iso20022.Payment_id.create ~end_to_end_id:"demo-payment-1" ()
                   |> Or_error.ok_exn)
                ~debtor:(party "Demo Customer" iban)
                ~creditor:(party "Payee" (Iban.of_string_exn payee))
                ()))
        ~now:(Time_ns.now ())
        ()
      |> Or_error.ok_exn
    in
    let%bind () =
      Fake_provider.initiate_transfer fake ~from:account.id draft |> ok >>= confirm fake
    in
    let%bind quote =
      ok (Fake_provider.quote_swap fake ~from:account.id ~to_:btc.id ~sell:(eur "100.00"))
    in
    let%bind () = Fake_provider.execute_swap fake quote.id |> ok >>= confirm fake in
    let%bind card =
      ok
        (Fake_provider.issue_virtual_card
           fake
           ~request_id:"demo-card"
           customer.id
           ~account:account.id)
    in
    let merchant =
      { Card_update.Merchant.name = "Demo Shop"
      ; mcc = Card_core.Mcc.of_int_exn 5411
      ; country = Card_core.Country.of_string "DE"
      }
    in
    let%bind response =
      ok (Fake_provider.simulate_card_auth fake card.id ~amount:(eur "9.99") ~merchant)
    in
    printf "card authorization: %s\n" (Card_core.Response_code.to_string response);
    let%bind () = Scheduler.yield_until_no_jobs_remain () in
    let%bind () =
      Deferred.List.iter ~how:`Sequential [ account.id; btc.id ] ~f:(fun id ->
        let%map b = ok (Fake_provider.balance fake id) in
        printf
          "balance %s: available %s, held %s\n"
          (Account_ref.to_string id)
          (Money.Amount.to_string b.available)
          (Money.Amount.to_string b.held))
    in
    Ledger.Trial_balance.of_balances (Ledger.Journal.balances journal)
    |> Ledger.Trial_balance.check
    |> Or_error.ok_exn;
    print_endline "trial balance: balanced";
    return ())
;;

let conformance () =
  let module Suite = Conformance.Make (Fake_provider) (Fake_provider) in
  with_journal None (fun journal ->
    let fake =
      Fake_provider.create ~time_source:(Time_source.wall_clock ()) ~journal ()
      |> Or_error.ok_exn
    in
    let%map results =
      Suite.run_all (Conformance.Config.default ~run_id:"cli") fake
    in
    List.iter results ~f:(fun (name, r) ->
      printf "%s %s\n" (if Or_error.is_ok r then "ok  " else "FAIL") name;
      Result.iter_error r ~f:(fun e -> printf "     %s\n" (Error.to_string_hum e)));
    List.exists results ~f:(fun (_, r) -> Or_error.is_error r))
  >>= function
  | true -> exit 1
  | false -> return ()
;;

let () =
  Command.group
    ~summary:"Banking provider boundary: run the deterministic fake offline"
    [ ( "demo"
      , Command.async
          ~summary:"Run a short customer journey against the fake provider"
          (let%map_open.Command journal =
             flag
               "-journal"
               (optional string)
               ~doc:"PATH write the ledger journal here (default: a temporary file)"
           in
           fun () -> demo journal) )
    ; ( "conformance"
      , Command.async
          ~summary:"Run the conformance suite against the fake provider"
          (Command.Param.return conformance) )
    ]
  |> Command_unix.run
;;
