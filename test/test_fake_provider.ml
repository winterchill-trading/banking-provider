open! Core
open Async
open Banking_provider
open Helpers

let%expect_test "onboarding: KYC events, an account and an IBAN" =
  with_fake (fun ~clock:_ ~journal:_ fake ->
    let events = event_printer fake in
    let%bind customer, account = onboard fake in
    events ();
    [%expect {|
      (evt_000001 (Kyc (customer cus_000001) (update (Status Submit))))
      (evt_000002 (Kyc (customer cus_000001) (update (Status Approve))))
      (evt_000003
       (Account_opened
        ((id acc_000001) (customer cus_000001) (currency EUR) (status Open)
         (addresses ()) (opened_at "2026-10-13 09:00:00Z"))))
      (evt_000004
       (Account_updated
        ((id acc_000001) (customer cus_000001) (currency EUR) (status Open)
         (addresses ((Iban (iban DE97500105170000000001) (bic ()))))
         (opened_at "2026-10-13 09:00:00Z"))))
      |}];
    let%bind status = ok (Fake_provider.kyc_status fake customer.id) in
    print_s [%sexp (status.status : Kyc_core.Status.t), (status.tier : Kyc_core.Tier.t)];
    print_s [%sexp (account.addresses : Account.Address.t list)];
    [%expect {|
      (Approved T0)
      ((Iban (iban DE97500105170000000001) (bic ())))
      |}];
    return ())
;;
