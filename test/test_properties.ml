open! Core
open Async
open Banking_provider
open Helpers
open Payments_core

let update_gen : Transfer_update.t Quickcheck.Generator.t =
  let open Quickcheck.Generator in
  let reason = of_list Iso_reason.[ AC01; AC04; AM04; MS02; FOCR; CUST; DUPL ] in
  union
    [ return Transfer_update.Submitted
    ; return Transfer_update.Pending
    ; return Transfer_update.Settled
    ; return Transfer_update.Cancelled
    ; return Transfer_update.Timed_out
    ; map reason ~f:(fun r -> Transfer_update.Rejected r)
    ; map reason ~f:(fun r -> Transfer_update.Returned r)
    ; map reason ~f:(fun r -> Transfer_update.Recall_requested r)
    ; map2 bool reason ~f:(fun accepted reason ->
        Transfer_update.Recall_answer { accepted; reason })
    ; map (of_list Iso20022.Transaction_status.[ ACSP; ACSC; ACCC; PDNG; ACTC ]) ~f:(fun status ->
        Transfer_update.Status_report { status; reason = None; value_date = None })
    ]
;;

let submitted rail =
  let account : Account.t =
    { id = Account_ref.of_string "acc"
    ; customer = Customer_ref.of_string "cus"
    ; currency = Money.Currency.eur
    ; status = Open
    ; addresses =
        [ Iban { iban = Iban.of_string_exn "DE97500105170000000001"; bic = None } ]
    ; opened_at = start
    }
  in
  let draft = sepa_draft ~rail ~id:"p" account (eur "10.00") in
  let draft = Transfer.exempt draft ~exemption:Low_value_remote |> ok_exn in
  Transfer.submit draft ~at:start () |> ok_exn
;;

let%expect_test "applying an update twice: the second time is stale" =
  Quickcheck.test
    ~sexp_of:[%sexp_of: Rail.t * Transfer_update.t list]
    Quickcheck.Generator.(
      tuple2
        (of_list [ Rail.Sepa_credit; Sepa_instant ])
        (list_with_length 6 update_gen))
    ~f:(fun (rail, updates) ->
      ignore
        (List.fold updates ~init:(submitted rail) ~f:(fun transfer update ->
           match Transfer_update.apply update transfer ~at:start () with
           | Error _ | Ok Stale -> transfer
           | Ok (Changed after) ->
             (match Transfer_update.apply update after ~at:start () with
              | Ok Stale -> after
              | other ->
                raise_s
                  [%message
                    "second application was not stale"
                      (update : Transfer_update.t)
                      (other : Transfer_update.Applied.t Or_error.t)]))
         : Transfer.t));
  return ()
;;

(* Runs a deferred the fake has already determined. *)
let now d =
  match Deferred.peek d with
  | Some x -> x
  | None -> failwith "the fake left work pending"
;;

type op =
  | Deposit of int
  | Pay of int
  | Card of int
  | Refund of int
[@@deriving sexp_of, quickcheck]

let op_gen =
  Quickcheck.Generator.(
    union
      [ map (Int.gen_incl 1 10_000) ~f:(fun c -> Deposit c)
      ; map (Int.gen_incl 1 10_000) ~f:(fun c -> Pay c)
      ; map (Int.gen_incl 1 5_000) ~f:(fun c -> Card c)
      ; map (Int.gen_incl 1 500) ~f:(fun c -> Refund c)
      ])
;;

let%expect_test "random activity keeps the books balanced and statements consistent" =
  let cents c = Money.Amount.of_minor_units_int Money.Currency.eur c in
  let trial = ref 0 in
  let%map () =
    with_dir (fun dir ->
      Quickcheck.test
        ~trials:30
        ~sexp_of:[%sexp_of: op list]
        (Quickcheck.Generator.list_with_length 12 op_gen)
        ~f:(fun ops ->
          incr trial;
          let clock = Time_source.create ~now:start () in
          let ts = Time_source.read_only clock in
          let journal =
            Ledger.Journal.create ~time_source:ts ~fsync:false (dir ^/ Int.to_string !trial)
            |> ok_exn
          in
          let fake = Fake_provider.create ~time_source:ts ~journal () |> ok_exn in
          (* [onboard] binds, and a bind runs as a later job even on a determined
             deferred; each fake call alone is determined at once. *)
          let customer =
            now
              (Fake_provider.create_customer
                 fake
                 ~customer_id:(Kyc_core.Customer_id.of_string "c")
                 ~person)
            |> ok_exn
          in
          now (Fake_provider.simulate_kyc_decision fake customer.id Approve) |> ok_exn;
          let account =
            now (Fake_provider.open_account fake customer.id Money.Currency.eur) |> ok_exn
          in
          let account = now (Fake_provider.enrich_account fake account.id) |> ok_exn in
          let card =
            now
              (Fake_provider.issue_virtual_card
                 fake
                 ~request_id:"r"
                 customer.id
                 ~account:account.id)
            |> ok_exn
          in
          List.iteri ops ~f:(fun i op ->
            Time_source.advance_directly_by clock (Time_ns.Span.of_sec 1.);
            match op with
            | Deposit c ->
              ignore
                (now
                   (Fake_provider.simulate_deposit
                      fake
                      ~account:account.id
                      ~rail:Sepa_instant
                      (cents c))
                 |> ok_exn
                 : Transfer.Id.t)
            | Pay c ->
              let draft =
                sepa_draft ~rail:Sepa_instant ~id:(sprintf "p%d" i) account (cents c)
              in
              (match now (Fake_provider.initiate_transfer fake ~from:account.id draft) with
               | Ok (Challenge ch) ->
                 ignore
                   (now (Fake_provider.confirm_sca fake ch.id ~code) |> ok_exn
                    : Sca_challenge.Result.t)
               | Ok (Done _) | Error _ -> ())
            | Card c ->
              ignore
                (now
                   (Fake_provider.simulate_card_auth
                      fake
                      card.id
                      ~amount:(cents c)
                      ~merchant:(merchant "Shop"))
                 |> ok_exn
                 : Card_core.Response_code.t)
            | Refund c ->
              now
                (Fake_provider.refund_card fake card.id ~amount:(cents c) ~merchant:(merchant "Shop"))
              |> ok_exn);
          Ledger.Trial_balance.of_balances (Ledger.Journal.balances journal)
          |> Ledger.Trial_balance.check
          |> ok_exn;
          let balance = now (Fake_provider.balance fake account.id) |> ok_exn in
          let statement =
            now
              (Fake_provider.statement
                 fake
                 account.id
                 ~from:start
                 ~until:(Time_ns.add start (Time_ns.Span.of_day 1.)))
            |> ok_exn
          in
          Statement.check statement |> ok_exn;
          if not (Money.Amount.equal statement.closing balance.posted)
          then raise_s [%message "statement disagrees" (statement : Statement.t)];
          if Money.Amount.is_negative balance.available
          then raise_s [%message "overdrawn" (balance : Account.Balance.t)];
          if not (List.is_empty (Fake_provider.background_errors fake))
          then
            raise_s
              [%message (Fake_provider.background_errors fake : Error.t list)];
          Ledger.Journal.close journal);
      return ())
  in
  ()
;;
