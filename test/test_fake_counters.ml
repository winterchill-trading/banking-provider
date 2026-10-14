open! Core
open Async
open Banking_provider
open Helpers

let%expect_test "a fake created with saved counters continues the ids" =
  let%bind () =
    with_dir (fun dir ->
      let clock = Time_source.create ~now:start () in
      let journal =
        Ledger.Journal.create
          ~time_source:(Time_source.read_only clock)
          ~fsync:false
          (dir ^/ "journal")
        |> ok_exn
      in
      let fake () ?counters () =
        Fake_provider.create
          ?counters
          ~time_source:(Time_source.read_only clock)
          ~journal
          ()
        |> ok_exn
      in
      let first = fake () () in
      let%bind (_ : Customer.t * Account.t) = onboard first in
      let saved = Fake_provider.counters first in
      print_s [%sexp (saved : (string * int) list)];
      let again = fake () ~counters:saved () in
      let%bind c =
        ok
          (Fake_provider.create_customer
             again
             ~customer_id:(Kyc_core.Customer_id.of_string "customer-2")
             ~person)
      in
      print_s [%sexp (Customer_ref.to_string c.id : string)];
      let%map () = return () in
      Ledger.Journal.close journal)
  in
  [%expect {|
    ((acc 1) (cus 1) (evt 4))
    cus_000002
    |}];
  return ()
;;
