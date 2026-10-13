open! Core
open Async
open Banking_provider
open Helpers

let key = Sensitive.of_string "test-key"

let%expect_test "timestamped signatures: valid, tampered, stale, missing" =
  let body = {|{"hello":"world"}|} in
  let header = Webhook.Timestamped.sign ~key ~at:start body in
  print_endline header;
  let request body = { Webhook.Request.headers = [ "X-Signature", header ]; body } in
  let check ?tolerance ~now r =
    print_s [%sexp (Webhook.Timestamped.verify ~key ?tolerance ~now r : unit Or_error.t)]
  in
  check ~now:start (request body);
  check ~now:start (request (body ^ " "));
  check ~now:(Time_ns.add start (Time_ns.Span.of_min 6.)) (request body);
  check ~tolerance:Time_ns.Span.zero ~now:(Time_ns.add start (Time_ns.Span.of_day 1.)) (request body);
  check ~now:start { headers = []; body };
  [%expect {|
    t=1791882000,v1=c99bc652bd186a4f31d095d42189a35f9b555ac6ec2a7311251d832ca2e82a88
    (Ok ())
    (Error "webhook signature: mismatch")
    (Error ("webhook signature: outside the replay window" (skew 6m)))
    (Ok ())
    (Error "webhook signature: missing header")
    |}];
  return ()
;;

let%expect_test "constant-time equality" =
  print_s
    [%sexp
      (Sensitive.constant_time_equal "abc" "abc" : bool)
      , (Sensitive.constant_time_equal "abc" "abd" : bool)
      , (Sensitive.constant_time_equal "abc" "abcd" : bool)
      , (Sensitive.constant_time_equal "" "" : bool)];
  print_s [%sexp (Sensitive.of_string "123456" : Sensitive.t)];
  [%expect {|
    (true false false true)
    <redacted>
    |}];
  return ()
;;

let%expect_test "redelivered webhooks, shuffled, reach the inbox once each" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let%bind _customer, account = onboard fake in
    let%bind (_ : Payments_core.Transfer.Id.t) =
      ok (Fake_provider.simulate_deposit fake ~account:account.id ~rail:Sepa_instant (eur "5.00"))
    in
    let%bind () = ok (Fake_provider.ping fake) in
    let deliveries = Fake_provider.webhook_deliveries fake in
    (* Every delivery twice, newest first: the order a retrying provider may produce. *)
    let replay = List.rev deliveries @ deliveries in
    let inbox = Inbox.create () in
    let%bind outcomes =
      Deferred.List.map ~how:`Sequential replay ~f:(fun request ->
        let%map events = ok (Fake_provider.ingest_webhook fake request) in
        List.map events ~f:(fun e -> ok_exn (Inbox.accept inbox e)))
    in
    let count o = List.count (List.concat outcomes) ~f:(Inbox.Outcome.equal o) in
    print_s
      [%message
        ""
          ~deliveries:(List.length deliveries : int)
          ~new_:(count New : int)
          ~duplicates:(count Duplicate : int)
          ~inbox:(Inbox.length inbox : int)];
    (* A body changed in transit fails before anything is parsed or published. *)
    let tampered = { (List.hd_exn deliveries) with body = "(tampered)" } in
    let%bind result = Fake_provider.ingest_webhook fake tampered in
    print_s [%sexp (result : Event.t list Or_error.t)];
    [%expect {|
      ((deliveries 6) (new_ 6) (duplicates 6) (inbox 6))
      (Error "webhook signature: mismatch")
      |}];
    return ())
;;

let%expect_test "an event id reused for other content is refused" =
  let inbox = Inbox.create () in
  let event kind = { Event.id = Event_id.of_string "evt-1"; at = start; kind } in
  print_s [%sexp (Inbox.accept inbox (event Ping) : Inbox.Outcome.t Or_error.t)];
  print_s [%sexp (Inbox.accept inbox (event Ping) : Inbox.Outcome.t Or_error.t)];
  print_s
    [%sexp
      (Inbox.accept
         inbox
         (event (Swap_failed { swap = Payments_core.Swap.Id.of_string "s"; reason = "x" }))
       : Inbox.Outcome.t Or_error.t)];
  [%expect {|
    (Ok New)
    (Ok Duplicate)
    (Error ("event id reused with different content" (id evt-1)))
    |}];
  return ()
;;

let%expect_test "subscribers see events as they are published" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let reader = Fake_provider.events fake in
    let%bind () = ok (Fake_provider.ping fake) in
    let%bind () = ok (Fake_provider.ping fake) in
    let%bind first = Pipe.read_exactly reader ~num_values:2 in
    (match first with
     | `Exactly q ->
       Queue.iter q ~f:(fun (e : Event.t) ->
         print_s [%sexp (Event_id.to_string e.id : string), (Event.Kind.name e.kind : string)])
     | `Eof | `Fewer _ -> print_endline "missing events");
    Pipe.close_read reader;
    let%bind () = ok (Fake_provider.ping fake) in
    [%expect {|
      (evt_000001 Ping)
      (evt_000002 Ping)
      |}];
    return ())
;;
