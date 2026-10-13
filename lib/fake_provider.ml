open! Core
open Async_kernel
open Payments_core
module Card = Card_core.Card
module Ids = Card_core.Ids
module Limits = Card_core.Limits
module Masked_pan = Card_core.Masked_pan
module Mcc = Card_core.Mcc
module Pan_display_token = Card_core.Pan_display_token
module Response_code = Card_core.Response_code

module Settlement = struct
  type t =
    | Immediate
    | Delayed of Time_ns.Span.t
    | Manual
  [@@deriving sexp, compare, equal]
end

module Config = struct
  type t =
    { settlement : Settlement.t
    ; sca : bool
    ; fee : Rail.t -> Money.Currency.t -> Money.Fee.t option
    ; rates : (Money.Currency.t * Money.Currency.t * string) list
    ; swap_spread_bps : int
    ; webhook_key : Sensitive.t
    ; auto_enrich : bool
    }

  let default =
    let open Money.Currency in
    { settlement = Immediate
    ; sca = true
    ; fee = (fun _ _ -> None)
    ; rates =
        [ btc, eur, "60000"; eth, eur, "2500"; usdc, eur, "0.92"; usdt, eur, "0.92" ]
    ; swap_spread_bps = 0
    ; (* Not a secret: it only signs the fake's own deliveries. *)
      webhook_key = Sensitive.of_string "fake-provider-webhook-key"
    ; auto_enrich = false
    }
  ;;
end

let sandbox_code = "123456"
let provider_name = "fake"

(* The currencies the fake opens accounts in, and the system accounts it needs. *)
let supported_currencies =
  Money.Currency.
    [ eur
    ; btc
    ; btc_lightning
    ; eth
    ; usdc
    ; usdt
    ; usdc_ethereum
    ; usdc_polygon
    ; usdc_solana
    ; usdt_ethereum
    ; usdt_tron
    ]
;;

type customer_state =
  { customer : Customer.t
  ; mutable kyc : Customer.Kyc_status.t
  }

type account_state =
  { mutable account : Account.t
  ; ledger : Ledger.Account_id.t
  }

type transfer_state =
  { mutable transfer : Transfer.t (** with our ledger account, not the caller's *)
  ; mutable updated_at : Time_ns.t
  }

type challenge_state =
  { mutable challenge : Sca.Challenge.t
  ; purpose : Sca_challenge.Purpose.t
  }

type swap_state =
  { quote : Swap.Quote.t
  ; swap_from : Account_ref.t
  ; swap_to : Account_ref.t
  ; mutable executed : bool
  }

type auth =
  { mutable auth : Card_core.Authorization.t
  ; auth_merchant : Card_core.Merchant.t
  }

type card_state =
  { mutable card : Card.t
  ; card_customer : Customer_ref.t
  ; card_account : Account_ref.t
  ; mutable details_unlocked_until : Time_ns.t option
  }

type order_state =
  { mutable order : Standing_order.t
  ; order_ref : Standing_order_ref.t
  ; order_from : Account_ref.t
  ; mutable confirmed_by : Sca.Id.t option
  ; mutable cancelled : bool
  }

type t =
  { config : Config.t
  ; time_source : Time_source.t
  ; journal : Ledger.Journal.t
  ; chart : Booking.Chart.t
  ; card_chart : Card_core.Booking.Chart.t
  ; counters : int String.Table.t
  ; customers : customer_state Customer_ref.Table.t
  ; customers_by_id : Customer_ref.t Kyc_core.Customer_id.Table.t
  ; accounts : account_state Account_ref.Table.t
  ; transfers : transfer_state Transfer.Id.Table.t
  ; challenges : challenge_state Sca.Id.Table.t
  ; swaps : swap_state Swap.Id.Table.t
  ; cards : card_state Ids.Card_id.Table.t
  ; card_requests : Ids.Card_id.t String.Table.t
  ; auths : auth Ids.Auth_id.Table.t
  ; orders : order_state Standing_order_ref.Table.t
  ; mutable subscribers : Event.t Pipe.Writer.t list
  ; published : Event.t Queue.t
  ; deliveries : Webhook.Request.t Queue.t
  ; background_errors : Error.t Queue.t
  }

let name (_ : t) = provider_name
let now t = Time_source.now t.time_source

let next_id t prefix =
  let n = 1 + Option.value (Hashtbl.find t.counters prefix) ~default:0 in
  Hashtbl.set t.counters ~key:prefix ~data:n;
  sprintf "%s_%06d" prefix n
;;

(* Sixteen-ish deterministic bytes per label, for addresses and preimages. *)
let digest label = Cryptokit.hash_string (Cryptokit.Hash.sha256 ()) label
let hex s = Cryptokit.transform_string (Cryptokit.Hexa.encode ()) s

let create ?(config = Config.default) ~time_source ~journal () =
  let open Or_error.Let_syntax in
  let chart = Booking.Chart.default in
  let card_chart = Card_core.Booking.Chart.default in
  let%map () =
    (* Both charts name the fee income accounts; open each id once. *)
    Booking.Chart.accounts chart ~rails:Rail.all ~currencies:supported_currencies
    @ Card_core.Booking.Chart.accounts card_chart ~currencies:supported_currencies
    |> List.stable_dedup
         ~compare:(Comparable.lift Ledger.Account_id.compare ~f:Ledger.Account.id)
    |> List.map ~f:(fun account ->
      Ledger.Journal.open_account journal account |> Or_error.map ~f:ignore)
    |> Or_error.all_unit
  in
  { config
  ; time_source = Time_source.read_only time_source
  ; journal
  ; chart
  ; card_chart
  ; counters = String.Table.create ()
  ; customers = Customer_ref.Table.create ()
  ; customers_by_id = Kyc_core.Customer_id.Table.create ()
  ; accounts = Account_ref.Table.create ()
  ; transfers = Transfer.Id.Table.create ()
  ; challenges = Sca.Id.Table.create ()
  ; swaps = Swap.Id.Table.create ()
  ; cards = Ids.Card_id.Table.create ()
  ; card_requests = String.Table.create ()
  ; auths = Ids.Auth_id.Table.create ()
  ; orders = Standing_order_ref.Table.create ()
  ; subscribers = []
  ; published = Queue.create ()
  ; deliveries = Queue.create ()
  ; background_errors = Queue.create ()
  }
;;

(* {2 Events} *)

let new_event t kind : Event.t =
  { id = Event_id.of_string (next_id t "evt"); at = now t; kind }
;;

let deliver t (event : Event.t) =
  t.subscribers <- List.filter t.subscribers ~f:(fun w -> not (Pipe.is_closed w));
  List.iter t.subscribers ~f:(fun w -> Pipe.write_without_pushback_if_open w event)
;;

let publish t (event : Event.t) =
  Queue.enqueue t.published event;
  let body = Sexp.to_string_mach (Event.sexp_of_t event) in
  let signature = Webhook.Timestamped.sign ~key:t.config.webhook_key ~at:(now t) body in
  Queue.enqueue
    t.deliveries
    { headers = [ Webhook.Timestamped.header_name, signature ]; body };
  deliver t event
;;

let emit t kind =
  let event = new_event t kind in
  publish t event;
  event
;;

let events t =
  let reader, writer = Pipe.create () in
  t.subscribers <- writer :: t.subscribers;
  reader
;;

let ingest_webhook t (request : Webhook.Request.t) =
  let result =
    let open Or_error.Let_syntax in
    let%bind () =
      Webhook.Timestamped.verify ~key:t.config.webhook_key ~now:(now t) request
    in
    let%map event =
      Or_error.try_with (fun () -> Event.t_of_sexp (Sexp.of_string request.body))
    in
    deliver t event;
    [ event ]
  in
  return result
;;

let webhook_deliveries t = Queue.to_list t.deliveries
let published t = Queue.to_list t.published
let background_errors t = Queue.to_list t.background_errors

(* Work that runs later has no caller; its errors are kept for tests to inspect. *)
let later t f =
  let run () =
    match f () with
    | Ok () -> ()
    | Error e -> Queue.enqueue t.background_errors e
  in
  match t.config.settlement with
  | Immediate -> run ()
  | Delayed span -> Time_source.run_after t.time_source span run ()
  | Manual -> ()
;;

(* {2 Lookups} *)

let find tbl key ~what ~sexp_of_key =
  match Hashtbl.find tbl key with
  | Some v -> Ok v
  | None -> Or_error.error_s [%message "not found" what (key : key)]
;;

let customer_state t id =
  find t.customers id ~what:"customer" ~sexp_of_key:Customer_ref.sexp_of_t
;;

let account_state t id =
  find t.accounts id ~what:"account" ~sexp_of_key:Account_ref.sexp_of_t
;;

let transfer_state t id =
  find t.transfers id ~what:"transfer" ~sexp_of_key:Transfer.Id.sexp_of_t
;;

let card_state t id = find t.cards id ~what:"card" ~sexp_of_key:Ids.Card_id.sexp_of_t
let ledger_account t id = Or_error.map (account_state t id) ~f:(fun a -> a.ledger)
let balances t = Ledger.Journal.balances t.journal

(* Booking and swap rules check their entries against the balances with this as
   [recorded_at], and the ledger refuses a time before its last record; the journal's own
   [now] never goes back, while the clock can stand still between two records. *)
let booking_time t = Ledger.Journal.now t.journal

(* Entries of one transition land together (one linked record), or not at all. *)
let post t = function
  | [] -> Ok ()
  | entries ->
    Booking.post t.journal entries
    |> Or_error.map ~f:(ignore : Ledger.Journal.Append_result.t -> unit)
;;

let ok_unit r = Or_error.map r ~f:(ignore : Ledger.Journal.Append_result.t -> unit)

(* {2 Customers and KYC} *)

let create_customer t ~customer_id ~person:(_ : Kyc_core.Person.t) =
  return
    (match Hashtbl.find t.customers_by_id customer_id with
     | Some id -> Or_error.map (customer_state t id) ~f:(fun c -> c.customer)
     | None ->
       let id = Customer_ref.of_string (next_id t "cus") in
       let customer = { Customer.id; customer_id; created_at = now t } in
       Hashtbl.set t.customers_by_id ~key:customer_id ~data:id;
       Hashtbl.set
         t.customers
         ~key:id
         ~data:{ customer; kyc = Customer.Kyc_status.initial id };
       Ok customer)
;;

let update_customer t id ~person:(_ : Kyc_core.Person.t) =
  (* The fake keeps no personal data at all: nothing it does depends on it, and a mock
     that stored it would invite real data into test fixtures. *)
  return (Or_error.map (customer_state t id) ~f:(ignore : customer_state -> unit))
;;

let kyc_status t id = return (Or_error.map (customer_state t id) ~f:(fun c -> c.kyc))

let set_step t (c : customer_state) step state =
  let open Or_error.Let_syntax in
  let from =
    List.Assoc.find_exn c.kyc.steps step ~equal:Kyc_core.Verification.Step.equal
  in
  let%map state = Kyc_core.Verification.transition ~from ~to_:state in
  c.kyc <- Customer.Kyc_status.with_step c.kyc step state;
  ignore
    (emit t (Kyc { customer = c.customer.id; update = Step { step; state } }) : Event.t)
;;

let set_status t (c : customer_state) transition =
  let open Or_error.Let_syntax in
  let%map status =
    Kyc_core.Status.apply c.kyc.status transition ~actor:(Provider provider_name)
  in
  c.kyc <- { c.kyc with status };
  ignore (emit t (Kyc { customer = c.customer.id; update = Status transition }) : Event.t)
;;

let is_code_step : Kyc_core.Verification.Step.t -> bool = function
  | Email | Mobile -> true
  | Identity_document | Liveness | Address_proof | Source_of_funds -> false
;;

let start_verification t id step =
  return
    (let open Or_error.Let_syntax in
     let%bind c = customer_state t id in
     let%map () = set_step t c step Sent in
     let expires_at = Time_ns.add (now t) (Time_ns.Span.of_min 10.) in
     if is_code_step step
     then Customer.Verification_session.Code_sent { step; expires_at }
     else
       Hosted
         { step
         ; token = Sensitive.of_string (next_id t "kyc_session")
         ; expires_at = Time_ns.add (now t) (Time_ns.Span.of_hr 1.)
         })
;;

let complete_verification t id step ~code =
  return
    (let open Or_error.Let_syntax in
     let%bind c = customer_state t id in
     let%bind () =
       if is_code_step step
       then Ok ()
       else Or_error.error_string "this step completes in the hosted flow"
     in
     let state : Kyc_core.Verification.State.t =
       if Sensitive.equal code (Sensitive.of_string sandbox_code)
       then Verified (now t)
       else Failed "wrong code"
     in
     let%map () = set_step t c step state in
     state)
;;

let simulate_kyc_decision t id (decision : Provider.Kyc_decision.t) =
  return
    (let open Or_error.Let_syntax in
     let%bind c = customer_state t id in
     let sent =
       List.filter_map c.kyc.steps ~f:(fun (step, state) ->
         match state with
         | Sent when not (is_code_step step) -> Some step
         | _ -> None)
     in
     let%bind () =
       match decision with
       | Approve ->
         List.map sent ~f:(fun step -> set_step t c step (Verified (now t)))
         |> Or_error.all_unit
       | Reject reason ->
         List.map sent ~f:(fun step -> set_step t c step (Failed reason))
         |> Or_error.all_unit
       | Request_resubmission _ -> Ok ()
     in
     let%bind () =
       match c.kyc.status with
       | Created | Needs_resubmission _ -> set_status t c Submit
       | _ -> Ok ()
     in
     match decision with
     | Approve -> set_status t c Approve
     | Reject reason -> set_status t c (Reject reason)
     | Request_resubmission fields -> set_status t c (Request_resubmission fields))
;;

(* {2 Accounts} *)

let network_of_currency (currency : Money.Currency.t)
  : [ `Chain of Network.t | `Lightning | `Fiat ] Or_error.t
  =
  match
    ( Money.Currency.kind currency
    , Money.Currency.code currency
    , Money.Currency.network currency )
  with
  | Fiat, "EUR", None -> Ok `Fiat
  | Fiat, _, _ ->
    Or_error.error_s [%message "the fake offers EUR only" (currency : Money.Currency.t)]
  | Crypto, "BTC", None -> Ok (`Chain Bitcoin)
  | Crypto, "BTC", Some "lightning" -> Ok `Lightning
  | Crypto, _, (None | Some "ethereum") -> Ok (`Chain Ethereum)
  | Crypto, _, Some "polygon" -> Ok (`Chain Polygon)
  | Crypto, _, Some "solana" -> Ok (`Chain Solana)
  | Crypto, _, Some "tron" -> Ok (`Chain Tron)
  | Crypto, _, Some _ ->
    Or_error.error_s [%message "no network for currency" (currency : Money.Currency.t)]
;;

(* Deterministic, well-formed addresses: the bytes are a hash of the account id. *)
let address_for t (account : Account.t) =
  let open Or_error.Let_syntax in
  let seed = digest ("fake-address:" ^ Account_ref.to_string account.id) in
  match%bind network_of_currency account.currency with
  | `Fiat ->
    (* German layout: 8-digit bank code and 10-digit account number. *)
    let number =
      Int.of_string (String.drop_prefix (Account_ref.to_string account.id) 4)
    in
    let bban = sprintf "50010517%010d" number in
    let check = Iban.check_digits ~country:"DE" ~bban in
    let%map iban = Iban.of_string ("DE" ^ check ^ bban) in
    Account.Address.Iban { iban; bic = None }
  | `Lightning -> Ok (Account.Address.Lightning_node { node_id = "02" ^ hex seed })
  | `Chain network ->
    let raw =
      match network with
      | Bitcoin ->
        Bech32.encode_segwit ~hrp:"bc" ~version:0 ~program:(String.prefix seed 20)
      | Bitcoin_testnet ->
        Bech32.encode_segwit ~hrp:"tb" ~version:0 ~program:(String.prefix seed 20)
      | Ethereum | Polygon -> "0x" ^ hex (String.prefix seed 20)
      | Tron -> Base58.encode_check ("\x41" ^ String.prefix seed 20)
      | Solana -> Base58.encode seed
    in
    let%map address = Crypto_address.create network raw in
    ignore t;
    Account.Address.Crypto { address; memo = None }
;;

let enrich t (a : account_state) =
  let open Or_error.Let_syntax in
  if not (List.is_empty a.account.addresses)
  then Ok a.account
  else (
    let%map address = address_for t a.account in
    a.account <- { a.account with addresses = [ address ] };
    ignore (emit t (Account_updated a.account) : Event.t);
    a.account)
;;

let open_account t id currency =
  return
    (let open Or_error.Let_syntax in
     let%bind c = customer_state t id in
     let%bind () =
       match c.kyc.status with
       | Approved -> Ok ()
       | status ->
         Or_error.error_s [%message "KYC not approved" (status : Kyc_core.Status.t)]
     in
     let%bind (_ : [ `Chain of Network.t | `Lightning | `Fiat ]) =
       network_of_currency currency
     in
     let existing =
       Hashtbl.data t.accounts
       |> List.find ~f:(fun a ->
         Customer_ref.equal a.account.customer id
         && Money.Currency.equal a.account.currency currency)
     in
     match existing with
     | Some a -> Ok a.account
     | None ->
       let account_id = Account_ref.of_string (next_id t "acc") in
       let ledger =
         Ledger.Account_id.of_string ("fake:" ^ Account_ref.to_string account_id)
       in
       let%bind () =
         Ledger.Journal.open_account
           t.journal
           (Ledger.Account.create
              ~purpose:Customer_funds
              ~tags:[ "customer", Customer_ref.to_string id ]
              ledger
              Liability)
         |> ok_unit
       in
       let account : Account.t =
         { id = account_id
         ; customer = id
         ; currency
         ; status = Open
         ; addresses = []
         ; opened_at = now t
         }
       in
       let a = { account; ledger } in
       Hashtbl.set t.accounts ~key:account_id ~data:a;
       ignore (emit t (Account_opened account) : Event.t);
       if t.config.auto_enrich then enrich t a else Ok account)
;;

let accounts t id =
  return
    (Or_error.map (customer_state t id) ~f:(fun _ ->
       Hashtbl.data t.accounts
       |> List.filter_map ~f:(fun a ->
         Option.some_if (Customer_ref.equal a.account.customer id) a.account)
       |> List.sort
            ~compare:
              (Comparable.lift Account_ref.compare ~f:(fun (a : Account.t) -> a.id))))
;;

let enrich_account t id = return (Or_error.bind (account_state t id) ~f:(enrich t))

let balance t id =
  return
    (Or_error.map (account_state t id) ~f:(fun a ->
       let b = balances t in
       let currency = a.account.currency in
       { Account.Balance.account = id
       ; available = Ledger.Balances.available b a.ledger currency
       ; held = Ledger.Balances.held b a.ledger currency
       ; posted = Ledger.Balances.posted b a.ledger currency
       ; as_of = now t
       }))
;;

let code_of_kind : Ledger.Entry.Kind.t -> string = function
  | Transfer tag -> String.uppercase tag
  | Reversal _ -> "REVERSAL"
  | Hold_place _ | Hold_place_expiring _ | Hold_increment _ -> "HOLD"
  | Hold_release _ | Hold_expire _ -> "HOLD_RELEASE"
  | Hold_capture _ | Hold_over_capture _ -> "CAPTURE"
;;

(* A bank statement shows posted money: the account together with its pending sub-account.
   Placing or releasing a hold moves money between the two and nets to zero, so it drops
   out; a capture shows as the payment. *)
let statement t id ~from ~until =
  return
    (let open Or_error.Let_syntax in
     let%bind a = account_state t id in
     let currency = a.account.currency in
     let records = Ledger.Journal.records t.journal in
     let side account = Ledger.Statement.create ~from ~until records ~account ~currency in
     let%bind main = side a.ledger in
     let%bind pending = side (Ledger.Account_id.pending a.ledger) in
     let signed (l : Ledger.Statement.Line.t) =
       match l.side with
       | Credit -> l.amount
       | Debit -> Money.Amount.neg l.amount
     in
     let%bind opening = Money.Amount.add main.opening pending.opening in
     let%bind _, lines =
       main.lines @ pending.lines
       |> List.sort_and_group ~compare:(fun (x : Ledger.Statement.Line.t) y ->
         Int.compare x.seq y.seq)
       |> List.fold_result ~init:(opening, []) ~f:(fun (running, acc) group ->
         let first = List.hd_exn group in
         let%bind amount = Money.Amount.sum currency (List.map group ~f:signed) in
         if Money.Amount.is_zero amount
         then Ok (running, acc)
         else (
           let%map balance = Money.Amount.add running amount in
           ( balance
           , { Statement.Line.at = first.effective_at
             ; amount
             ; code = code_of_kind first.kind
             ; reference = first.reference
             ; balance
             }
             :: acc )))
     in
     let lines = List.rev lines in
     let closing =
       Option.value_map (List.last lines) ~default:opening ~f:(fun l -> l.balance)
     in
     Ok { Statement.account = id; currency; from; until; opening; lines; closing })
;;

(* {2 Transfers} *)

let info (s : transfer_state) : Transfer_info.t =
  { transfer = s.transfer.id
  ; provider_ref = Option.value s.transfer.provider_ref ~default:""
  ; status = s.transfer.status
  ; fee = s.transfer.fee
  ; details = s.transfer.details
  ; updated_at = s.updated_at
  }
;;

let fee_for t ~rail amount =
  match t.config.fee rail (Money.Amount.currency amount) with
  | None -> Ok (Money.Amount.zero (Money.Amount.currency amount))
  | Some fee -> Money.Fee.compute fee ~side:Receivable amount
;;

let quote_fee t ~from ~rail amount =
  return
    (let open Or_error.Let_syntax in
     let%bind a = account_state t from in
     let%bind () =
       if Money.Currency.equal a.account.currency (Money.Amount.currency amount)
       then Ok ()
       else Or_error.error_string "amount is not in the account's currency"
     in
     let%bind fee = fee_for t ~rail amount in
     let%map total = Money.Amount.add amount fee in
     { Transfer_info.Fee_quote.rail; amount; fee; total })
;;

(* Moves a transfer by a provider update: applies it to the state machine, books the
   ledger entries for any status change under the new event's id, then publishes. *)
let apply_update t (s : transfer_state) (update : Transfer_update.t) =
  let open Or_error.Let_syntax in
  let at = now t in
  match%bind Transfer_update.apply update s.transfer ~at () with
  | Stale -> Ok ()
  | Changed after ->
    let event =
      new_event
        t
        (Transfer
           { transfer = s.transfer.id
           ; provider_ref = Option.value s.transfer.provider_ref ~default:""
           ; update
           })
    in
    let%bind () =
      if Transfer.Status.equal after.status s.transfer.status
      then Ok ()
      else
        Booking.transition
          t.chart
          (balances t)
          s.transfer
          ~to_:after.status
          ~event_id:(Event.booking_event_id event)
          ~at:(booking_time t)
        |> Or_error.bind ~f:(post t)
    in
    s.transfer <- after;
    s.updated_at <- at;
    publish t event;
    Ok ()
;;

(* What the scheme does once a payment is submitted, by rail. *)
let settle_steps t (s : transfer_state) : Transfer_update.t list =
  match s.transfer.rail, s.transfer.details with
  | Lightning, Lightning { payment_hash = Some _; _ } ->
    let preimage =
      hex (digest ("fake-preimage:" ^ Transfer.Id.to_string s.transfer.id))
    in
    [ Lightning_paid { preimage } ]
  | Onchain _, _ ->
    let tx = digest ("fake-tx:" ^ Transfer.Id.to_string s.transfer.id) in
    [ Confirmations
        { tx_hash = hex tx
        ; block_hash = hex (digest tx)
        ; confirmations = 1
        ; finalized = false
        }
    ; Settled
    ]
  | Sepa_credit, _ -> [ Pending; Settled ]
  | (Sepa_instant | Lightning | Intraledger | Card_scheme), _ ->
    ignore t;
    [ Settled ]
;;

let schedule_settlement t (s : transfer_state) =
  later t (fun () ->
    List.fold_result (settle_steps t s) ~init:() ~f:(fun () update ->
      apply_update t s update))
;;

(* Submits an authorized transfer: holds the funds, or fails it when they are not there. *)
let submit t (s : transfer_state) =
  let open Or_error.Let_syntax in
  let at = now t in
  let%bind submitted =
    Transfer.submit s.transfer ?provider_ref:s.transfer.provider_ref ~at ()
  in
  let event =
    new_event
      t
      (Transfer
         { transfer = s.transfer.id
         ; provider_ref = Option.value s.transfer.provider_ref ~default:""
         ; update = Submitted
         })
  in
  match
    Booking.transition
      t.chart
      (balances t)
      s.transfer
      ~to_:Submitted
      ~event_id:(Event.booking_event_id event)
      ~at:(booking_time t)
  with
  | Error _ ->
    (* The hold failed: not enough available. The payment fails on our side. *)
    let%map failed =
      Transfer.transition s.transfer ~to_:(Failed Insufficient_funds) ~at
    in
    s.transfer <- failed;
    s.updated_at <- at;
    (* The [Submitted] event was never published; its id goes to the failure instead. *)
    publish
      t
      { event with
        kind =
          Transfer
            { transfer = s.transfer.id
            ; provider_ref = Option.value s.transfer.provider_ref ~default:""
            ; update = Failed Insufficient_funds
            }
      }
  | Ok entries ->
    let%map () = post t entries in
    s.transfer <- submitted;
    s.updated_at <- at;
    publish t event;
    schedule_settlement t s
;;

let new_challenge t ~subject ~purpose ~operation ~amount ~payee =
  let open Or_error.Let_syntax in
  let id = Sca.Id.of_string (next_id t "sca") in
  let binding = Sca.Binding.create ~operation ~amount ~payee in
  let%map challenge =
    Sca.Challenge.create ~id ~subject ~binding ~factors:[ Otp; Pin ] ~now:(now t) ()
  in
  Hashtbl.set t.challenges ~key:id ~data:{ challenge; purpose };
  challenge
;;

let challenge_view (c : Sca.Challenge.t) purpose : Sca_challenge.t =
  { id = c.id
  ; purpose
  ; factors = [ Otp ]
  ; expires_at = c.expires_at
  ; attempts_left = c.max_attempts - c.attempts
  }
;;

let payee_of (transfer : Transfer.t) =
  match transfer.counterparty with
  | Beneficiary b -> Beneficiary.Id.to_string b.id
  | External { detail; _ } -> detail
;;

let customer_of_account t from =
  Or_error.map (account_state t from) ~f:(fun a ->
    Customer_ref.to_string a.account.customer)
;;

(* Lightning payments to an address or LNURL get a payment hash we can settle with a
   preimage; an invoice's hash belongs to the payee, so those settle without one. *)
let with_lightning_hash (transfer : Transfer.t) =
  match transfer.rail, transfer.details with
  | Lightning, Lightning { payment_hash = None; preimage = None } ->
    (match transfer.counterparty with
     | Beneficiary { destination = Lightning (Invoice _); _ } -> transfer
     | _ ->
       let preimage = digest ("fake-preimage:" ^ Transfer.Id.to_string transfer.id) in
       let payment_hash = hex (digest preimage) in
       { transfer with
         details = Lightning { payment_hash = Some payment_hash; preimage = None }
       })
  | _ -> transfer
;;

let initiate_transfer t ~from (draft : Transfer.t) =
  return
    (let open Or_error.Let_syntax in
     match Hashtbl.find t.transfers draft.id with
     | Some s ->
       (* A resent request: the same transfer, whatever state it reached. *)
       (match s.transfer.status, s.transfer.authorization with
        | Awaiting_sca, Some (Sca challenge) ->
          let%map c =
            find t.challenges challenge ~what:"challenge" ~sexp_of_key:Sca.Id.sexp_of_t
          in
          Sca_challenge.Or_challenge.Challenge (challenge_view c.challenge c.purpose)
        | _ -> Ok (Done (info s)))
     | None ->
       let%bind a = account_state t from in
       let%bind () =
         match draft.status, draft.direction with
         | Draft, Out -> Ok ()
         | status, _ ->
           Or_error.error_s
             [%message
               "only outgoing drafts can be initiated" (status : Transfer.Status.t)]
       in
       let%bind () =
         if Money.Currency.equal a.account.currency (Money.Amount.currency draft.amount)
         then Ok ()
         else Or_error.error_string "amount is not in the account's currency"
       in
       let%bind fee = fee_for t ~rail:draft.rail draft.amount in
       let transfer =
         with_lightning_hash
           { draft with account = a.ledger; fee; provider_ref = Some (next_id t "tr") }
       in
       let at = now t in
       let s = { transfer; updated_at = at } in
       if t.config.sca
       then (
         let%bind subject = customer_of_account t from in
         let purpose = Sca_challenge.Purpose.Transfer draft.id in
         let%bind challenge =
           new_challenge
             t
             ~subject
             ~purpose
             ~operation:"transfer"
             ~amount:(Transfer.total_debit transfer)
             ~payee:(payee_of transfer)
         in
         let%map transfer = Transfer.require_sca transfer ~challenge:challenge.id ~at in
         s.transfer <- transfer;
         Hashtbl.set t.transfers ~key:draft.id ~data:s;
         Sca_challenge.Or_challenge.Challenge (challenge_view challenge purpose))
       else (
         let%bind () =
           match transfer.authorization with
           | Some _ -> Ok ()
           | None ->
             Or_error.error_string
               "SCA is off in this fake: the draft must carry its own authorization"
         in
         Hashtbl.set t.transfers ~key:draft.id ~data:s;
         let%map () = submit t s in
         Sca_challenge.Or_challenge.Done (info s)))
;;

let transfer t id = return (Or_error.map (transfer_state t id) ~f:info)

let cancel_transfer t id =
  return
    (let open Or_error.Let_syntax in
     let%bind s = transfer_state t id in
     let%bind () =
       match s.transfer.status with
       | Draft | Awaiting_sca -> Ok ()
       | status ->
         Or_error.error_s
           [%message "already submitted to the scheme" (status : Transfer.Status.t)]
     in
     let%map () = apply_update t s Cancelled in
     (match s.transfer.authorization with
      | Some (Sca challenge) ->
        Hashtbl.change
          t.challenges
          challenge
          ~f:
            (Option.map ~f:(fun c ->
               { c with challenge = Sca.Challenge.cancel c.challenge }))
      | _ -> ());
     info s)
;;

let simulate_transfer_outcome t id update =
  return (Or_error.bind (transfer_state t id) ~f:(fun s -> apply_update t s update))
;;

(* {2 Deposits} *)

(* The example IBAN printed in many public IBAN references; it validates and belongs to no
   customer of ours. *)
let sandbox_sender_iban = "DE89370400440532013000"
let sandbox_sender_name = "Sandbox Sender"

(* SEPA identifiers may not contain '_'. *)
let sepa_id s = String.tr s ~target:'_' ~replacement:'-'

let deposit_details t (a : account_state) ~rail ~provider_ref
  : (Transfer.Details.t * Transfer.Counterparty.t * bool) Or_error.t
  =
  let open Or_error.Let_syntax in
  match (rail : Rail.t) with
  | Sepa_credit | Sepa_instant ->
    let%bind creditor_iban =
      Account.iban a.account
      |> Or_error.of_option ~error:(Error.of_string "account has no IBAN yet; enrich it")
    in
    let debtor_iban = Iban.of_string_exn sandbox_sender_iban in
    let party name iban = { Iso20022.Party.name; iban; bic = None; address = None } in
    let%map payment_id =
      Iso20022.Payment_id.create ~end_to_end_id:(sepa_id provider_ref) ()
    in
    ( Transfer.Details.Sepa
        (Sepa.Details.create
           ~payment_id
           ~debtor:(party sandbox_sender_name debtor_iban)
           ~creditor:(party "Account Holder" creditor_iban)
           ())
    , Transfer.Counterparty.External
        { name = sandbox_sender_name; detail = Iban.to_string debtor_iban }
    , true )
  | Onchain _ ->
    Ok
      ( Transfer.Details.Onchain
          { travel_rule = None
          ; tx_hash = None
          ; block_hash = None
          ; confirmations = 0
          ; finalized = false
          }
      , Transfer.Counterparty.External { name = "on-chain sender"; detail = "" }
      , false )
  | Lightning ->
    let preimage = digest ("fake-preimage:" ^ provider_ref) in
    Ok
      ( Transfer.Details.Lightning
          { payment_hash = Some (hex (digest preimage)); preimage = Some (hex preimage) }
      , Transfer.Counterparty.External { name = "Lightning payer"; detail = "" }
      , true )
  | Intraledger ->
    Ok
      ( Transfer.Details.Intraledger
      , Transfer.Counterparty.External { name = "internal"; detail = "" }
      , true )
  | Card_scheme ->
    ignore t;
    Or_error.error_string "card refunds come from refund_card, not a deposit"
;;

let simulate_deposit t ~account ~rail amount =
  return
    (let open Or_error.Let_syntax in
     let%bind a = account_state t account in
     let%bind () =
       if Money.Currency.equal a.account.currency (Money.Amount.currency amount)
       then Ok ()
       else Or_error.error_string "amount is not in the account's currency"
     in
     let provider_ref = next_id t "dep" in
     let%bind details, from, settled = deposit_details t a ~rail ~provider_ref in
     let id = Event.incoming_transfer_id ~provider_ref in
     let event =
       new_event
         t
         (Incoming_transfer
            { account
            ; transfer = id
            ; provider_ref
            ; rail
            ; amount
            ; fee = Money.Amount.zero (Money.Amount.currency amount)
            ; from
            ; reference = "deposit " ^ provider_ref
            ; details
            ; settled
            })
     in
     let%bind transfer =
       Option.value_exn (Event.incoming_transfer event ~account:a.ledger)
     in
     let%bind entries =
       Booking.created
         t.chart
         (balances t)
         transfer
         ~event_id:(Event.booking_event_id event)
         ~at:(booking_time t)
     in
     let%map () = post t entries in
     let s = { transfer; updated_at = now t } in
     Hashtbl.set t.transfers ~key:id ~data:s;
     publish t event;
     if not settled
     then (
       let tx = digest ("fake-tx:" ^ provider_ref) in
       later t (fun () ->
         (* Enough for any confirmation policy: six blocks and finalized. *)
         apply_update
           t
           s
           (Confirmations
              { tx_hash = hex tx
              ; block_hash = hex (digest tx)
              ; confirmations = 6
              ; finalized = true
              })));
     id)
;;

(* {2 Swaps} *)

let quote_swap t ~from ~to_ ~sell =
  return
    (let open Or_error.Let_syntax in
     let%bind a = account_state t from in
     let%bind b = account_state t to_ in
     let%bind () =
       if Customer_ref.equal a.account.customer b.account.customer
       then Ok ()
       else Or_error.error_string "both accounts must belong to one customer"
     in
     let%bind () =
       if Money.Currency.equal a.account.currency (Money.Amount.currency sell)
       then Ok ()
       else Or_error.error_string "amount is not in the selling account's currency"
     in
     let buy = b.account.currency in
     let connects (base, quote, _) =
       (Money.Currency.equal base a.account.currency && Money.Currency.equal quote buy)
       || (Money.Currency.equal base buy && Money.Currency.equal quote a.account.currency)
     in
     let%bind base, quote, price =
       List.find t.config.rates ~f:connects
       |> Or_error.of_option
            ~error:
              (Error.create_s
                 [%message
                   "no rate"
                     ~sell:(a.account.currency : Money.Currency.t)
                     (buy : Money.Currency.t)])
     in
     let%bind price = Money.Rate.price_of_string price in
     let%bind market =
       Money.Rate.create ~base ~quote ~price ~at:(now t) ~source:provider_name
     in
     let%map quote =
       Swap.Quote.create
         ~id:(Swap.Id.of_string (next_id t "swp"))
         ~market
         ~sell
         ~buy
         ~spread_bps:t.config.swap_spread_bps
         ~now:(now t)
         ()
     in
     Hashtbl.set
       t.swaps
       ~key:quote.id
       ~data:{ quote; swap_from = from; swap_to = to_; executed = false };
     quote)
;;

let do_swap t (s : swap_state) =
  let open Or_error.Let_syntax in
  let%bind a = account_state t s.swap_from in
  let%bind b = account_state t s.swap_to in
  let event =
    new_event
      t
      (Swap_executed
         { swap = s.quote.id; sell = s.quote.sell; fee = s.quote.fee; buy = s.quote.buy })
  in
  match
    Swap.execute
      t.chart
      (balances t)
      s.quote
      ~from_:a.ledger
      ~to_:b.ledger
      ~event_id:(Event.booking_event_id event)
      ~now:(booking_time t)
  with
  | Error e ->
    ignore
      (emit t (Swap_failed { swap = s.quote.id; reason = Error.to_string_hum e })
       : Event.t);
    Ok ()
  | Ok entries ->
    let%map (_ : Ledger.Journal.Append_result.t) =
      Ledger.Journal.append_linked t.journal entries
    in
    s.executed <- true;
    publish t event
;;

let execute_swap t id =
  return
    (let open Or_error.Let_syntax in
     let%bind s = find t.swaps id ~what:"swap quote" ~sexp_of_key:Swap.Id.sexp_of_t in
     if s.executed
     then Ok (Sca_challenge.Or_challenge.Done ())
     else if t.config.sca
     then (
       let%bind subject = customer_of_account t s.swap_from in
       let purpose = Sca_challenge.Purpose.Swap id in
       let%map challenge =
         new_challenge
           t
           ~subject
           ~purpose
           ~operation:"swap"
           ~amount:s.quote.sell
           ~payee:(Account_ref.to_string s.swap_to)
       in
       Sca_challenge.Or_challenge.Challenge (challenge_view challenge purpose))
     else (
       let%map () = do_swap t s in
       Sca_challenge.Or_challenge.Done ()))
;;

(* {2 Cards} *)

let card_info (c : card_state) : Card_info.t =
  { id = c.card.id
  ; customer = c.card_customer
  ; account = c.card_account
  ; kind = c.card.kind
  ; status = c.card.status
  ; masked_pan = c.card.masked_pan
  ; limits = c.card.limits
  ; created_at = c.card.created_at
  }
;;

let issue_virtual_card t ~request_id customer ~account =
  return
    (let open Or_error.Let_syntax in
     match Hashtbl.find t.card_requests request_id with
     | Some id -> Or_error.map (card_state t id) ~f:card_info
     | None ->
       let%bind a = account_state t account in
       let%bind () =
         if Customer_ref.equal a.account.customer customer
         then Ok ()
         else Or_error.error_string "the funding account belongs to another customer"
       in
       let raw_id = next_id t "card" in
       let id = Ids.Card_id.of_string raw_id in
       let at = now t in
       let%bind card =
         Card.request
           ~id
           ~holder:(Customer_ref.to_string customer)
           ~account:a.ledger
           ~currency:a.account.currency
           ~kind:Virtual
           ~at
           ()
       in
       let n = Int.of_string (String.drop_prefix raw_id 5) in
       let date = Time_ns.to_date at ~zone:Time_float.Zone.utc in
       let%bind expiry =
         Masked_pan.Expiry.create
           ~month:(Month.to_int (Date.month date))
           ~year:(Date.year date + 3)
       in
       let%bind last4 =
         Masked_pan.Last4.of_string_or_error (sprintf "%04d" (n % 10_000))
       in
       let%map card = Card.activate card ~masked_pan:{ last4; expiry } ~at in
       let c =
         { card
         ; card_customer = customer
         ; card_account = account
         ; details_unlocked_until = None
         }
       in
       Hashtbl.set t.cards ~key:id ~data:c;
       Hashtbl.set t.card_requests ~key:request_id ~data:id;
       ignore (emit t (Card { card = id; update = Status_changed Active }) : Event.t);
       card_info c)
;;

let card t id = return (Or_error.map (card_state t id) ~f:card_info)

let cards t customer =
  return
    (Or_error.map (customer_state t customer) ~f:(fun _ ->
       Hashtbl.data t.cards
       |> List.filter ~f:(fun c -> Customer_ref.equal c.card_customer customer)
       |> List.map ~f:card_info
       |> List.sort
            ~compare:
              (Comparable.lift Ids.Card_id.compare ~f:(fun (c : Card_info.t) -> c.id))))
;;

let set_card_status t id status =
  return
    (let open Or_error.Let_syntax in
     let%bind c = card_state t id in
     let before = c.card.status in
     let%map card = Card.transition c.card ~to_:status ~at:(now t) in
     c.card <- card;
     if not (Card.Status.equal before card.status)
     then
       ignore (emit t (Card { card = id; update = Status_changed card.status }) : Event.t);
     card_info c)
;;

let set_card_limits t id limits =
  return
    (let open Or_error.Let_syntax in
     let%bind c = card_state t id in
     let%map card = Card.set_limits c.card limits ~at:(now t) in
     c.card <- card;
     card_info c)
;;

(* How long a passed challenge unlocks the card-number component. *)
let details_window = Time_ns.Span.of_min 5.

let card_details_token t id =
  return
    (let open Or_error.Let_syntax in
     let%bind c = card_state t id in
     let unlocked =
       (not t.config.sca)
       ||
       match c.details_unlocked_until with
       | Some until -> Time_ns.( < ) (now t) until
       | None -> false
     in
     if unlocked
     then (
       let%map token =
         Pan_display_token.of_provider
           ~token:(next_id t "pan_token")
           ~expires_at:(Time_ns.add (now t) details_window)
       in
       Sca_challenge.Or_challenge.Done token)
     else (
       let purpose = Sca_challenge.Purpose.Card_details id in
       let%map challenge =
         new_challenge
           t
           ~subject:(Customer_ref.to_string c.card_customer)
           ~purpose
           ~operation:"card_details"
           ~amount:(Money.Amount.zero c.card.currency)
           ~payee:(Ids.Card_id.to_string id)
       in
       Sca_challenge.Or_challenge.Challenge (challenge_view challenge purpose)))
;;

let auths_of_card t (c : card_state) =
  Hashtbl.data t.auths
  |> List.filter_map ~f:(fun a ->
    Option.some_if (Ids.Card_id.equal a.auth.card_id c.card.id) a.auth)
;;

(* Card bookings come from card-core's rules; an empty list books nothing. *)
let post_card t entries =
  match entries with
  | [] -> Ok ()
  | entries ->
    Ledger.Journal.append_linked t.journal entries
    |> Or_error.map ~f:(ignore : Ledger.Journal.Append_result.t -> unit)
;;

let card_event t card_id update = new_event t (Card { card = card_id; update })

let clear_auth t (a : auth) ?amount () =
  let open Or_error.Let_syntax in
  let%bind c = card_state t a.auth.card_id in
  let billing = Option.value amount ~default:(Card_core.Authorization.open_hold a.auth) in
  let%bind merchant = Card_core.Merchant.with_amount a.auth_merchant billing in
  let%bind clearing =
    Card_core.Settlement.Clearing.create
      ~id:(Ids.Clearing_id.of_string (next_id t "clr"))
      ~card_id:c.card.id
      ~network_txn_id:a.auth.network_txn_id
      ~auth_id:a.auth.id
      ~direction:Debit
      ~merchant
      ~billing_currency:c.card.currency
        (* card-core books a clearing at its own [at]: it must not be behind the journal's
           last record. *)
      ~at:(booking_time t)
      ()
  in
  let%bind outcome = Card_core.Settlement.settle clearing ~auth:(Some a.auth) in
  let event = card_event t c.card.id (Clearing clearing) in
  let%bind entries =
    Card_core.Booking.settled
      t.card_chart
      (balances t)
      c.card
      clearing
      outcome
      ~event_id:(Event.booking_event_id event)
  in
  let%map () = post_card t entries in
  (match outcome with
   | Against_auth { auth; _ } -> a.auth <- auth
   | Without_auth | Refund _ -> ());
  publish t event
;;

(* The merchant ran 3-D Secure and the cardholder passed it, so the decision does not ask
   for SCA again (code 1A); the conformance suite needs a plain approval. *)
let authenticated : Card_core.Three_ds.t =
  { trans_status = Y; eci = Some 5; cavv_present = true }
;;

let simulate_card_auth t id (merchant : Card_core.Merchant.t) =
  return
    (let open Or_error.Let_syntax in
     let%bind c = card_state t id in
     let%bind acct = account_state t c.card_account in
     let%bind () =
       if Money.Currency.equal c.card.currency (Money.Amount.currency merchant.amount)
       then Ok ()
       else Or_error.error_string "the fake charges in the card's billing currency only"
     in
     let at = now t in
     let request : Card_core.Authorization.Request.t =
       { auth_id = Ids.Auth_id.of_string (next_id t "auth")
       ; card_id = id
       ; network_txn_id = Ids.Network_txn_id.of_string (next_id t "ntx")
       ; kind = Auth
       ; amount = merchant.amount
       ; merchant
       ; entry_mode = Ecommerce
       ; initiator = Cardholder
       ; estimated = false
       ; partial_supported = false
       ; three_ds = Some authenticated
       ; exemption = None
       ; cardholder_verified = false
       ; at
       }
     in
     let%bind usage =
       Card_core.Authorization.usage (auths_of_card t c) ~currency:c.card.currency ~now:at
     in
     let decision =
       Card_core.Decision.decide
         { card = c.card
         ; usage
         ; available = Ledger.Balances.available (balances t) acct.ledger c.card.currency
         ; sca_policy = Card_core.Card_sca.Policy.default
         ; sca_counters = Sca.Counters.zero
         ; request
         ; open_auth = None
         }
         ~now:at
     in
     let%bind pending = Card_core.Authorization.pending request in
     let%bind auth = Card_core.Decision.apply decision pending ~request in
     let response = Card_core.Decision.response_code decision in
     let event =
       card_event
         t
         id
         (Auth_request
            { auth = auth.id
            ; network_txn = auth.network_txn_id
            ; amount = auth.requested
            ; approved = auth.approved
            ; merchant
            ; entry_mode = auth.entry_mode
            ; response
            ; decided_by = auth.decided_by
            })
     in
     let%bind entries =
       Card_core.Booking.authorized
         (balances t)
         c.card
         auth
         ~event_id:(Event.booking_event_id event)
         ~at:(booking_time t)
     in
     let%map () = post_card t entries in
     let a = { auth; auth_merchant = merchant } in
     Hashtbl.set t.auths ~key:auth.id ~data:a;
     publish t event;
     if Card_core.Response_code.is_approved response
     then
       later t (fun () ->
         if Card_core.Authorization.Status.is_open a.auth.status
         then clear_auth t a ()
         else Ok ());
     response)
;;

let auth_state t id =
  find t.auths id ~what:"authorization" ~sexp_of_key:Ids.Auth_id.sexp_of_t
;;

let clear_card_auth t id ?amount () =
  return (Or_error.bind (auth_state t id) ~f:(fun a -> clear_auth t a ?amount ()))
;;

let reverse_card_auth t id ?amount () =
  return
    (let open Or_error.Let_syntax in
     let%bind a = auth_state t id in
     let%bind c = card_state t a.auth.card_id in
     let%bind auth, released =
       Card_core.Authorization.reverse a.auth ?amount ~at:(now t) ()
     in
     let event = card_event t c.card.id (Reversal { auth = id; amount = released }) in
     let%bind entries =
       Card_core.Booking.reversed
         (balances t)
         a.auth
         ~amount:released
         ~event_id:(Event.booking_event_id event)
         ~at:(booking_time t)
     in
     let%map () = post_card t entries in
     a.auth <- auth;
     publish t event)
;;

let expire_card_auths t =
  return
    (let open Or_error.Let_syntax in
     let at = now t in
     Hashtbl.data t.auths
     |> List.sort ~compare:(Comparable.lift Ids.Auth_id.compare ~f:(fun a -> a.auth.id))
     |> List.filter ~f:(fun a -> Card_core.Authorization.is_due_to_expire a.auth ~now:at)
     |> List.fold_result ~init:[] ~f:(fun expired a ->
       let event = card_event t a.auth.card_id (Expiry { auth = a.auth.id }) in
       let%bind entries =
         Card_core.Booking.expired
           (balances t)
           a.auth
           ~event_id:(Event.booking_event_id event)
           ~at:(booking_time t)
       in
       let%bind () = post_card t entries in
       let%map auth, (_ : Money.Amount.t) =
         Card_core.Authorization.expire a.auth ~now:at
       in
       a.auth <- auth;
       publish t event;
       auth.id :: expired)
     |> Or_error.map ~f:List.rev)
;;

let simulate_card_advice t id (merchant : Card_core.Merchant.t) ~response =
  return
    (let open Or_error.Let_syntax in
     let%bind c = card_state t id in
     let request : Card_core.Authorization.Request.t =
       { auth_id = Ids.Auth_id.of_string (next_id t "auth")
       ; card_id = id
       ; network_txn_id = Ids.Network_txn_id.of_string (next_id t "ntx")
       ; kind = Advice
       ; amount = merchant.amount
       ; merchant
       ; entry_mode = Chip
       ; initiator = Cardholder
       ; estimated = false
       ; partial_supported = false
       ; three_ds = None
       ; exemption = None
       ; cardholder_verified = true
       ; at = now t
       }
     in
     let approved =
       if Card_core.Response_code.is_approved response
       then merchant.amount
       else Money.Amount.zero c.card.currency
     in
     let%bind auth =
       Card_core.Authorization.advice
         request
         ~approved
         ~response_code:response
         ~decided_by:Stand_in
     in
     let event =
       card_event
         t
         id
         (Auth_advice
            { auth = auth.id
            ; network_txn = auth.network_txn_id
            ; amount = auth.requested
            ; approved = auth.approved
            ; merchant
            ; entry_mode = auth.entry_mode
            ; response
            ; decided_by = auth.decided_by
            })
     in
     (* card-core holds the approved amount. A stand-in approval above the available
        balance cannot be held, so this returns an error for it; card-core books such a
        shortfall only when the clearing arrives. *)
     let%bind entries =
       Card_core.Booking.authorized
         (balances t)
         c.card
         auth
         ~event_id:(Event.booking_event_id event)
         ~at:(booking_time t)
     in
     let%map () = post_card t entries in
     Hashtbl.set t.auths ~key:auth.id ~data:{ auth; auth_merchant = merchant };
     publish t event;
     auth.id)
;;

let refund_card t id (merchant : Card_core.Merchant.t) =
  return
    (let open Or_error.Let_syntax in
     let%bind c = card_state t id in
     let%bind clearing =
       Card_core.Settlement.Clearing.create
         ~id:(Ids.Clearing_id.of_string (next_id t "clr"))
         ~card_id:c.card.id
         ~direction:Credit
         ~merchant
         ~billing_currency:c.card.currency
         ~at:(booking_time t)
         ()
     in
     let%bind outcome = Card_core.Settlement.settle clearing ~auth:None in
     let event = card_event t c.card.id (Clearing clearing) in
     let%bind entries =
       Card_core.Booking.settled
         t.card_chart
         (balances t)
         c.card
         clearing
         outcome
         ~event_id:(Event.booking_event_id event)
     in
     let%map () = post_card t entries in
     publish t event)
;;

(* {2 Standing orders} *)

let create_standing_order t ~from (order : Standing_order.t) =
  return
    (let open Or_error.Let_syntax in
     let%bind a = account_state t from in
     let%bind () =
       if Money.Currency.equal a.account.currency (Money.Amount.currency order.amount)
       then Ok ()
       else Or_error.error_string "amount is not in the account's currency"
     in
     let order_ref = Standing_order_ref.of_string (next_id t "so") in
     let s =
       { order; order_ref; order_from = from; confirmed_by = None; cancelled = false }
     in
     Hashtbl.set t.orders ~key:order_ref ~data:s;
     if t.config.sca
     then (
       let purpose = Sca_challenge.Purpose.Standing_order order_ref in
       let%map challenge =
         new_challenge
           t
           ~subject:(Customer_ref.to_string a.account.customer)
           ~purpose
           ~operation:"standing_order"
           ~amount:order.amount
           ~payee:(Beneficiary.Id.to_string order.beneficiary.id)
       in
       Sca_challenge.Or_challenge.Challenge (challenge_view challenge purpose))
     else Ok (Sca_challenge.Or_challenge.Done order_ref))
;;

let cancel_standing_order t id =
  return
    (Or_error.map
       (find t.orders id ~what:"standing order" ~sexp_of_key:Standing_order_ref.sexp_of_t)
       ~f:(fun s ->
         s.cancelled <- true;
         s.order <- Standing_order.cancel s.order))
;;

let is_confirmed t s = Option.is_some s.confirmed_by || not t.config.sca

let run_standing_orders t =
  return
    (let open Or_error.Let_syntax in
     Hashtbl.data t.orders
     |> List.sort
          ~compare:(Comparable.lift Standing_order_ref.compare ~f:(fun s -> s.order_ref))
     |> List.filter ~f:(fun s -> (not s.cancelled) && is_confirmed t s)
     |> List.fold_result ~init:[] ~f:(fun started s ->
       match%bind Standing_order.run s.order ~now:(now t) ~zone:Time_float.Zone.utc with
       | None -> Ok started
       | Some (order, draft) ->
         s.order <- order;
         if Hashtbl.mem t.transfers draft.id
         then Ok started
         else (
           let%bind a = account_state t s.order_from in
           let%bind fee = fee_for t ~rail:draft.rail draft.amount in
           (* The SCA that confirmed the order authorizes its first run; later runs carry
              the recurring-payment exemption from payments-core. *)
           let authorization =
             match draft.authorization, s.confirmed_by with
             | Some auth, _ -> Some auth
             | None, Some challenge -> Some (Sca.Authorization.Sca challenge)
             | None, None -> Some (Exempt Recurring_same_amount_payee)
           in
           let transfer =
             with_lightning_hash
               { draft with
                 account = a.ledger
               ; fee
               ; authorization
               ; provider_ref = Some (next_id t "tr")
               }
           in
           let ts = { transfer; updated_at = now t } in
           Hashtbl.set t.transfers ~key:draft.id ~data:ts;
           ignore
             (emit
                t
                (Standing_order_run
                   { order = s.order_ref
                   ; run_date = Option.value_exn order.last_run
                   ; transfer = draft.id
                   })
              : Event.t);
           let%map () = submit t ts in
           draft.id :: started))
     |> Or_error.map ~f:List.rev)
;;

(* {2 SCA} *)

let accepted t (c : challenge_state) =
  match c.purpose with
  | Transfer id ->
    let%bind.Or_error s = transfer_state t id in
    (match s.transfer.status with
     | Awaiting_sca -> submit t s
     | _ -> Ok ())
  | Swap id ->
    let%bind.Or_error s = find t.swaps id ~what:"swap" ~sexp_of_key:Swap.Id.sexp_of_t in
    if s.executed then Ok () else do_swap t s
  | Standing_order id ->
    let%map.Or_error s =
      find t.orders id ~what:"standing order" ~sexp_of_key:Standing_order_ref.sexp_of_t
    in
    s.confirmed_by <- Some c.challenge.id
  | Card_details id ->
    let%map.Or_error card = card_state t id in
    card.details_unlocked_until <- Some (Time_ns.add (now t) details_window)
;;

let failed t (c : challenge_state) =
  match c.purpose with
  | Transfer id ->
    let%bind.Or_error s = transfer_state t id in
    (match s.transfer.status with
     | Awaiting_sca -> apply_update t s (Failed Sca_failed)
     | _ -> Ok ())
  | Swap _ | Standing_order _ | Card_details _ -> Ok ()
;;

let confirm_sca t id ~code =
  return
    (let open Or_error.Let_syntax in
     let%bind c = find t.challenges id ~what:"challenge" ~sexp_of_key:Sca.Id.sexp_of_t in
     let at = now t in
     let challenge, outcome =
       if Sensitive.equal code (Sensitive.of_string sandbox_code)
       then (
         (* One sandbox code stands for both elements, as one OTP completes SCA in
            provider sandboxes; the challenge still records two categories. *)
         let challenge, outcome =
           Sca.record c.challenge ~now:at ~kind:Otp ~correct:true
         in
         match outcome with
         | Factor_accepted _ -> Sca.record challenge ~now:at ~kind:Pin ~correct:true
         | _ -> challenge, outcome)
       else Sca.record c.challenge ~now:at ~kind:Otp ~correct:false
     in
     c.challenge <- challenge;
     match outcome with
     | Verified ->
       let%map () = accepted t c in
       Sca_challenge.Result.Accepted
     | Already_verified -> Ok Sca_challenge.Result.Accepted
     | Wrong_response { attempts_left } ->
       if attempts_left = 0
       then (
         let%map () = failed t c in
         Sca_challenge.Result.Failed Too_many_attempts)
       else Ok (Wrong_code { attempts_left })
     | Rejected failure ->
       let%map () = failed t c in
       Sca_challenge.Result.Failed failure
     | (Factor_accepted _ | Binding_mismatch | Not_a_factor _) as outcome ->
       Or_error.error_s [%message "unexpected SCA outcome" (outcome : Sca.Outcome.t)])
;;

(* {2 Other simulations} *)

let simulate_payee_check t beneficiary result =
  return (Ok (ignore (emit t (Payee_check { beneficiary; result }) : Event.t)))
;;

let ping t = return (Ok (ignore (emit t Ping : Event.t)))
