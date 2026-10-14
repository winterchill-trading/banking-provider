open! Core
open Async_kernel
open Payments_core

module Config = struct
  type t =
    { run_id : string
    ; person : Kyc_core.Person.t
    ; sca_code : Sensitive.t
    ; payee_iban : string
    ; deposit : Money.Amount.t
    ; payment : Money.Amount.t
    ; timeout : Time_ns.Span.t
    ; poll_interval : Time_ns.Span.t
    ; currency : Money.Currency.t
    ; rail : Rail.t
    ; payee : string option
    ; kyc_delay : Time_ns.Span.t
    }

  let eur s = Money.Amount.of_decimal_string Money.Currency.eur s |> Or_error.ok_exn

  let synthetic_person =
    let open Kyc_core in
    { Person.given_name = Pii.create "Test"
    ; family_name = Pii.create "Customer"
    ; date_of_birth = Pii.create (Date.create_exn ~y:1990 ~m:Jan ~d:1)
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

  let gbp s = Money.Amount.of_decimal_string Money.Currency.gbp s |> Or_error.ok_exn

  let synthetic_uk_person =
    let open Kyc_core in
    { synthetic_person with
      nationality = Pii.create (Country.of_string "GB")
    ; residential_address =
        Pii.create
          { Address.line1 = "1 Test Street"
          ; line2 = None
          ; city = "London"
          ; region = None
          ; postal_code = Some "EC1A 1BB"
          ; country = Country.of_string "GB"
          }
    ; (* From the range the UK regulator keeps for drama and testing. *)
      mobile = Pii.create "+447700900000"
    }
  ;;

  let usd s = Money.Amount.of_decimal_string Money.Currency.usd s |> Or_error.ok_exn

  let synthetic_us_person =
    let open Kyc_core in
    { synthetic_person with
      nationality = Pii.create (Country.of_string "US")
    ; residential_address =
        Pii.create
          { Address.line1 = "1 Test Street"
          ; line2 = None
          ; city = "Springfield"
          ; region = Some "IL"
          ; postal_code = Some "62701"
          ; country = Country.of_string "US"
          }
    ; (* 555-0100 to 555-0199 are reserved for fiction. *)
      mobile = Pii.create "+12175550100"
    }
  ;;

  let default ~run_id =
    { run_id
    ; person = synthetic_person
    ; sca_code = Sensitive.of_string "123456"
    ; (* The example creditor IBAN printed in public IBAN references. *)
      payee_iban = "FR1420041010050500013M02606"
    ; deposit = eur "100.00"
    ; payment = eur "30.00"
    ; timeout = Time_ns.Span.of_sec 10.
    ; poll_interval = Time_ns.Span.of_ms 50.
    ; currency = Money.Currency.eur
    ; rail = Sepa_instant
    ; payee = None
    ; kyc_delay = Time_ns.Span.of_ms 200.
    }
  ;;

  let gbp ~run_id =
    { (default ~run_id) with
      person = synthetic_uk_person
    ; deposit = gbp "100.00"
    ; payment = gbp "30.00"
    ; currency = Money.Currency.gbp
    ; rail = Faster_payments
    ; (* A sort code no bank uses, so a sandbox cannot reach a real account. *)
      payee = Some "99-00-00 87654321"
    }
  ;;

  let usd ~run_id =
    { (default ~run_id) with
      person = synthetic_us_person
    ; deposit = usd "100.00"
    ; payment = usd "30.00"
    ; currency = Money.Currency.usd
    ; rail = Ach { sec = Ppd; same_day = false }
    ; (* A routing number with a valid check digit, not looked up anywhere. *)
      payee = Some "123456780 000987654 checking"
    }
  ;;

  let payee t = Option.value t.payee ~default:t.payee_iban
end

(* The functor's argument is called [Sandbox] too; this keeps the module's helpers in
   reach. *)
module Sandbox_lib = Sandbox

module Make (P : Provider.S) (Sandbox : Sandbox.S with type t = P.t) = struct
  type scenario =
    { name : string
    ; run : P.t -> unit Or_error.t Deferred.t
    }

  open Deferred.Or_error.Let_syntax

  let check cond fmt =
    ksprintf (fun msg -> if cond then Ok () else Or_error.error_string msg) fmt
  ;;

  let check_d cond fmt = ksprintf (fun msg -> Deferred.return (check cond "%s" msg)) fmt

  (* Polls [f] until it gives [Some x], or fails after the timeout. *)
  let poll (config : Config.t) ~what f =
    let deadline = Time_ns.add (Time_ns.now ()) config.timeout in
    let rec loop () =
      match%bind.Deferred f () with
      | Error _ as e -> Deferred.return e
      | Ok (Some x) -> return x
      | Ok None ->
        if Time_ns.( > ) (Time_ns.now ()) deadline
        then Deferred.Or_error.error_s [%message "timed out waiting" what]
        else (
          let%bind.Deferred () = Clock_ns.after config.poll_interval in
          loop ())
    in
    loop ()
  ;;

  (* Reads events until one satisfies [f], or fails after the timeout. *)
  let await (config : Config.t) reader ~what f =
    let rec loop () =
      match%bind.Deferred Pipe.read reader with
      | `Eof -> Deferred.Or_error.error_s [%message "event stream ended" what]
      | `Ok event ->
        (match f event with
         | Some x -> return x
         | None -> loop ())
    in
    match%bind.Deferred Clock_ns.with_timeout config.timeout (loop ()) with
    | `Result r -> Deferred.return r
    | `Timeout -> Deferred.Or_error.error_s [%message "timed out waiting for event" what]
  ;;

  let customer_id (config : Config.t) suffix =
    Kyc_core.Customer_id.of_string (config.run_id ^ "-" ^ suffix)
  ;;

  let approved_customer config t suffix =
    let%bind customer =
      P.create_customer t ~customer_id:(customer_id config suffix) ~person:config.person
    in
    let%bind () = Sandbox.simulate_kyc_decision t customer.id Approve in
    let%map (_ : Customer.Kyc_status.t) =
      poll config ~what:"KYC approved" (fun () ->
        let%map status = P.kyc_status t customer.id in
        match status.status with
        | Approved -> Some status
        | _ -> None)
    in
    customer
  ;;

  let is_sepa (config : Config.t) = Option.is_some (Sepa.Scheme.of_rail config.rail)

  (* What the account needs before money can arrive on the configured rail. *)
  let address_wanted (config : Config.t) =
    if is_sepa config
    then "an IBAN"
    else if Rail.is_uk config.rail
    then "a sort code and account number"
    else if Rail.is_us config.rail
    then "a routing and account number"
    else "an address"
  ;;

  let has_address (config : Config.t) account =
    if is_sepa config
    then Option.is_some (Account.iban account)
    else if Rail.is_uk config.rail
    then Option.is_some (Account.uk_account account)
    else if Rail.is_us config.rail
    then Option.is_some (Account.us_account account)
    else not (List.is_empty account.Account.addresses)
  ;;

  let rail_account (config : Config.t) t customer =
    let%bind account = P.open_account t customer config.currency in
    poll
      config
      ~what:(address_wanted config ^ " on the account")
      (fun () ->
        let%map account = P.enrich_account t account.id in
        Option.some_if (has_address config account) account)
  ;;

  (* The EUR scenario keeps its original name, so earlier reports still line up. *)
  let account_scenario_name (config : Config.t) =
    if is_sepa config && Money.Currency.equal config.currency Money.Currency.eur
    then "an approved customer gets an EUR account with an IBAN"
    else
      sprintf
        "an approved customer gets a %s account with %s"
        (Money.Currency.code config.currency)
        (address_wanted config)
  ;;

  let available config t account ~what ~f =
    poll config ~what (fun () ->
      let%map balance = P.balance t account in
      Option.some_if (f balance.Account.Balance.available) balance.available)
  ;;

  let equal_amount a b = Money.Amount.equal a b

  let funded config t suffix =
    let%bind customer = approved_customer config t suffix in
    let%bind account = rail_account config t customer.id in
    let%bind (_ : Transfer.Id.t) =
      Sandbox.simulate_deposit t ~account:account.id ~rail:config.rail config.deposit
    in
    let%map (_ : Money.Amount.t) =
      available config t account.id ~what:"the deposit" ~f:(equal_amount config.deposit)
    in
    customer, account
  ;;

  let payee_beneficiary (config : Config.t) ~owner ~id =
    Beneficiary.create
      ~id:(Beneficiary.Id.of_string ("ben-" ^ id))
      ~owner:(Customer_ref.to_string owner)
      ~name:"Payee"
      ~rail:config.rail
      ~now:(Time_ns.now ())
      (Config.payee config)
  ;;

  let domestic_draft (config : Config.t) (account : Account.t) ~id amount =
    Deferred.return
      (let open Or_error.Let_syntax in
       let%bind beneficiary = payee_beneficiary config ~owner:account.customer ~id in
       Transfer.draft
         ~id:(Transfer.Id.of_string id)
         ~rail:config.rail
         ~account:(Ledger.Account_id.of_string "conformance:app")
         ~beneficiary
         ~amount
         ~reference:"conformance"
         ~now:(Time_ns.now ())
         ())
  ;;

  let sepa_draft (config : Config.t) (account : Account.t) ~id amount =
    Deferred.return
      (let open Or_error.Let_syntax in
       let%bind beneficiary = payee_beneficiary config ~owner:account.customer ~id in
       let%bind debtor_iban =
         Account.iban account |> Or_error.of_option ~error:(Error.of_string "no IBAN")
       in
       let%bind creditor_iban = Iban.of_string (Config.payee config) in
       let party name iban = { Iso20022.Party.name; iban; bic = None; address = None } in
       let%bind payment_id =
         Iso20022.Payment_id.create ~end_to_end_id:(String.prefix id 35) ()
       in
       Transfer.draft
         ~id:(Transfer.Id.of_string id)
         ~rail:config.rail
         ~account:(Ledger.Account_id.of_string "conformance:app")
         ~beneficiary
         ~amount
         ~details:
           (Sepa
              (Sepa.Details.create
                 ~payment_id
                 ~debtor:(party "Test Customer" debtor_iban)
                 ~creditor:(party "Payee" creditor_iban)
                 ()))
         ~now:(Time_ns.now ())
         ())
  ;;

  (* A draft on the configured rail: SEPA details for SEPA rails; the UK and US rails fill
     in their own. *)
  let draft config account ~id amount =
    if is_sepa config
    then sepa_draft config account ~id amount
    else domestic_draft config account ~id amount
  ;;

  (* Answers a challenge if there is one. *)
  let authorize (config : Config.t) t = function
    | Sca_challenge.Or_challenge.Done x -> return (`Done x)
    | Challenge c ->
      let%bind result = P.confirm_sca t c.id ~code:config.sca_code in
      (match result with
       | Accepted -> return `Confirmed
       | other ->
         Deferred.Or_error.error_s
           [%message "SCA not accepted" (other : Sca_challenge.Result.t)])
  ;;

  (* Settled or a state no transition leaves. *)
  let finished config t id =
    poll config ~what:"the transfer to finish" (fun () ->
      let%map info = P.transfer t id in
      Option.some_if
        (Transfer.Status.is_final info.status || Transfer.Status.equal info.status Settled)
        info)
  ;;

  let scenarios (config : Config.t) =
    [ { name = "create_customer is idempotent on our customer id"
      ; run =
          (fun t ->
            let customer_id = customer_id config "idem" in
            let%bind a = P.create_customer t ~customer_id ~person:config.person in
            let%bind b = P.create_customer t ~customer_id ~person:config.person in
            check_d
              (Customer_ref.equal a.id b.id)
              "a second create_customer made another customer")
      }
    ; { name = "a KYC approval is published as an event and reported by kyc_status"
      ; run =
          (fun t ->
            let events = P.events t in
            let%bind customer = approved_customer config t "kyc" in
            let%map () =
              await config events ~what:"KYC Approve event" (fun (e : Event.t) ->
                match e.kind with
                | Kyc { customer = c; update = Status Approve }
                  when Customer_ref.equal c customer.id -> Some ()
                | _ -> None)
            in
            Pipe.close_read events)
      }
    ; { name = account_scenario_name config
      ; run =
          (fun t ->
            let%bind customer = approved_customer config t "account" in
            let%bind account = rail_account config t customer.id in
            let%bind accounts = P.accounts t customer.id in
            check_d
              (List.exists accounts ~f:(fun a -> Account_ref.equal a.id account.id))
              "accounts does not list the opened account")
      }
    ; { name = "a deposit is published once and credits the balance"
      ; run =
          (fun t ->
            let%bind customer = approved_customer config t "deposit" in
            let%bind account = rail_account config t customer.id in
            let events = P.events t in
            let%bind id =
              Sandbox.simulate_deposit
                t
                ~account:account.id
                ~rail:config.rail
                config.deposit
            in
            let%bind () =
              await config events ~what:"Incoming_transfer" (fun (e : Event.t) ->
                match e.kind with
                | Incoming_transfer { transfer; amount; _ }
                  when Transfer.Id.equal transfer id ->
                  Option.some_if (equal_amount amount config.deposit) ()
                | _ -> None)
            in
            Pipe.close_read events;
            let%map (_ : Money.Amount.t) =
              available
                config
                t
                account.id
                ~what:"the deposit"
                ~f:(equal_amount config.deposit)
            in
            ())
      }
    ; { name = "a payment confirmed by SCA settles and debits amount plus fee"
      ; run =
          (fun t ->
            let%bind _customer, account = funded config t "pay" in
            let%bind quote =
              P.quote_fee t ~from:account.id ~rail:config.rail config.payment
            in
            let%bind draft =
              draft config account ~id:(config.run_id ^ "-pay-1") config.payment
            in
            let%bind started = P.initiate_transfer t ~from:account.id draft in
            let%bind (_ : [ `Done of Transfer_info.t | `Confirmed ]) =
              authorize config t started
            in
            let%bind info = finished config t draft.id in
            let%bind () =
              check_d
                (Transfer.Status.equal info.status Settled)
                !"payment ended %{sexp: Transfer.Status.t}"
                info.status
            in
            let%bind expected =
              Deferred.return (Money.Amount.sub config.deposit quote.total)
            in
            let%map (_ : Money.Amount.t) =
              available config t account.id ~what:"the debit" ~f:(equal_amount expected)
            in
            ())
      }
    ; { name = "initiating the same transfer twice pays once"
      ; run =
          (fun t ->
            let%bind _customer, account = funded config t "resend" in
            let%bind draft =
              draft config account ~id:(config.run_id ^ "-resend-1") config.payment
            in
            let%bind first = P.initiate_transfer t ~from:account.id draft in
            let%bind (_ : [ `Done of Transfer_info.t | `Confirmed ]) =
              authorize config t first
            in
            let%bind (_ : Transfer_info.t) = finished config t draft.id in
            let%bind second = P.initiate_transfer t ~from:account.id draft in
            let%bind () =
              match second with
              | Done _ -> return ()
              | Challenge _ ->
                Deferred.Or_error.error_string "a resent, finished transfer asked for SCA"
            in
            let%bind quote =
              P.quote_fee t ~from:account.id ~rail:config.rail config.payment
            in
            let%bind expected =
              Deferred.return (Money.Amount.sub config.deposit quote.total)
            in
            let%bind balance = P.balance t account.id in
            check_d
              (equal_amount balance.available expected)
              !"paid twice? available %{Money.Amount}"
              balance.available)
      }
    ; { name = "a payment above the balance does not leave the account"
      ; run =
          (fun t ->
            let%bind _customer, account = funded config t "overdraw" in
            let too_much = Money.Amount.scale config.deposit 2 in
            let%bind draft =
              draft config account ~id:(config.run_id ^ "-over-1") too_much
            in
            (* Refusing at once and failing afterwards are both acceptable. *)
            let%bind () =
              match%bind.Deferred P.initiate_transfer t ~from:account.id draft with
              | Error _ -> return ()
              | Ok started ->
                (match%bind.Deferred authorize config t started with
                 | Error _ -> return ()
                 | Ok _ ->
                   let%bind info = finished config t draft.id in
                   check_d
                     (not (Transfer.Status.equal info.status Settled))
                     "an overdrawing payment settled")
            in
            let%bind balance = P.balance t account.id in
            check_d
              (equal_amount balance.available config.deposit)
              !"available changed to %{Money.Amount}"
              balance.available)
      }
    ; { name = "a wrong SCA code is refused without naming a factor"
      ; run =
          (fun t ->
            let%bind _customer, account = funded config t "wrong-code" in
            let%bind draft =
              draft config account ~id:(config.run_id ^ "-wrong-1") config.payment
            in
            match%bind P.initiate_transfer t ~from:account.id draft with
            | Done _ -> return () (* this provider did not ask for SCA here *)
            | Challenge c ->
              let%bind result =
                P.confirm_sca t c.id ~code:(Sensitive.of_string "not-the-code")
              in
              (match result with
               | Wrong_code _ | Failed _ -> return ()
               | Accepted -> Deferred.Or_error.error_string "a wrong code was accepted"))
      }
    ; { name = "a webhook with a bad signature is refused"
      ; run =
          (fun t ->
            match%bind.Deferred
              P.ingest_webhook
                t
                { headers = [ "x-signature", "t=0,v1=00"; "signature", "00" ]
                ; body = "{}"
                }
            with
            | Ok _ -> Deferred.Or_error.error_string "an unsigned webhook was accepted"
            | Error _ -> return ())
      }
    ; { name = "a test delivery arrives as a Ping event"
      ; run =
          (fun t ->
            let events = P.events t in
            let%bind () = Sandbox.ping t in
            let%map () =
              await config events ~what:"Ping" (fun (e : Event.t) ->
                match e.kind with
                | Ping -> Some ()
                | _ -> None)
            in
            Pipe.close_read events)
      }
    ; { name = "a virtual card is approved, and declined with 57 once frozen"
      ; run =
          (fun t ->
            let%bind customer, account = funded config t "card" in
            let%bind card =
              P.issue_virtual_card
                t
                ~request_id:(config.run_id ^ "-card-1")
                customer.id
                ~account:account.id
            in
            let%bind again =
              P.issue_virtual_card
                t
                ~request_id:(config.run_id ^ "-card-1")
                customer.id
                ~account:account.id
            in
            let%bind () =
              check_d
                (Card_core.Ids.Card_id.equal card.id again.id)
                "a resent card request issued a second card"
            in
            let one = Money.Amount.of_minor_units_int config.currency 100 in
            let%bind merchant =
              Deferred.return
                (Card_core.Merchant.create
                   ~name:"Conformance Shop"
                   ~mcc:(Card_core.Mcc.of_int_exn 5411)
                   ~country:
                     (Card_core.Country.of_string
                        (if Money.Currency.equal config.currency Money.Currency.gbp
                         then "GB"
                         else if Money.Currency.equal config.currency Money.Currency.usd
                         then "US"
                         else "DE"))
                   ~amount:one)
            in
            let%bind approved = Sandbox.simulate_card_auth t card.id merchant in
            let%bind () =
              check_d
                (Card_core.Response_code.is_approved approved)
                !"declined with %{Card_core.Response_code}"
                approved
            in
            let%bind (_ : Card_info.t) = P.set_card_status t card.id Frozen in
            let%bind frozen = Sandbox.simulate_card_auth t card.id merchant in
            check_d
              (Card_core.Response_code.equal frozen Not_permitted)
              !"frozen card answered %{Card_core.Response_code}"
              frozen)
      }
    ; { name = "an account keeps its details when opened and enriched again"
      ; run =
          (fun t ->
            let%bind customer = approved_customer config t "details" in
            let%bind account = rail_account config t customer.id in
            let%bind again = P.open_account t customer.id config.currency in
            let%bind enriched = P.enrich_account t account.id in
            let%bind listed = P.accounts t customer.id in
            let same_details (other : Account.t) =
              List.equal Account.Address.equal account.addresses other.addresses
            in
            let%bind () =
              check_d
                (Account_ref.equal again.id account.id)
                "a second open_account opened another account"
            in
            let%bind () =
              check_d (same_details enriched) "enriching again changed the details"
            in
            check_d
              (List.exists listed ~f:(fun a ->
                 Account_ref.equal a.id account.id && same_details a))
              "accounts shows other details for the account")
      }
    ; { name = "a KYC decision set to wait comes after its delay"
      ; run =
          (fun t ->
            let%bind customer =
              P.create_customer
                t
                ~customer_id:(customer_id config "kyc-delay")
                ~person:config.person
            in
            match%bind.Deferred
              Sandbox.set_kyc_simulation
                t
                ~customer:customer.id
                (Decide { outcome = Approved; delay = config.kyc_delay })
            with
            | Error e when Sandbox_lib.is_unsupported e ->
              (* A sandbox without the control has nothing to check here. *)
              return ()
            | Error _ as e -> Deferred.return e
            | Ok () ->
              let%bind (_ : Customer.Verification_session.t) =
                P.start_verification t customer.id Identity_document
              in
              let%bind early = P.kyc_status t customer.id in
              let%bind () =
                check_d
                  (not (Kyc_core.Status.equal early.status Approved))
                  "approved before the delay"
              in
              let%map (_ : Customer.Kyc_status.t) =
                poll config ~what:"the delayed KYC approval" (fun () ->
                  let%map status = P.kyc_status t customer.id in
                  match status.status with
                  | Approved -> Some status
                  | _ -> None)
              in
              ())
      }
    ; { name = "verify_payee answers, and a simulated answer is returned"
      ; run =
          (fun t ->
            let%bind customer = approved_customer config t "payee" in
            let%bind beneficiary =
              Deferred.return
                (payee_beneficiary
                   config
                   ~owner:customer.id
                   ~id:(config.run_id ^ "-payee-1"))
            in
            let%bind (_ : Beneficiary.Payee_check.t) =
              P.verify_payee t ~customer:customer.id beneficiary
            in
            let expected =
              Beneficiary.Payee_check.Close_match { suggested_name = "P Ayee" }
            in
            let%bind () = Sandbox.simulate_payee_check t beneficiary.id expected in
            let%bind result = P.verify_payee t ~customer:customer.id beneficiary in
            check_d
              (Beneficiary.Payee_check.equal result expected)
              !"simulated %{sexp: Beneficiary.Payee_check.t}, got %{sexp: \
                Beneficiary.Payee_check.t}"
              expected
              result)
      }
    ]
  ;;

  let run_all config t =
    Deferred.List.map ~how:`Sequential (scenarios config) ~f:(fun s ->
      let%map.Deferred result =
        Monitor.try_with_or_error ~extract_exn:true (fun () -> s.run t)
        |> Deferred.map ~f:Or_error.join
      in
      s.name, result)
  ;;
end
