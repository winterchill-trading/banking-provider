(** Scenarios every {!Provider.S} implementation must pass, in the currency and over the
    rail of the {!Config} ({!Config.default}: EUR over SCT Inst; {!Config.gbp}: GBP over
    Faster Payments).

    The fake passes them in this repository's tests; an adapter for a real provider runs
    the same functor against its sandbox (behind an environment gate, since that needs
    credentials). The scenarios rely only on the contract in {!Provider.S}: results are
    awaited as events or by polling, within [timeout], so a sandbox that provisions an
    IBAN minutes later or settles a payment asynchronously still passes. Every customer id
    starts with [run_id], so reruns against a shared sandbox do not collide.

    Each scenario returns [Ok ()] or an error saying what did not hold. *)

open! Core
open Async_kernel
open Payments_core

module Config : sig
  type t =
    { run_id : string (** prefix of every customer id, e.g. a timestamp *)
    ; person : Kyc_core.Person.t (** synthetic; sent to the provider as the customer *)
    ; sca_code : Sensitive.t (** what the sandbox accepts as an OTP *)
    ; payee_iban : string (** a valid SEPA IBAN the sandbox may pay *)
    ; deposit : Money.Amount.t (** credited by the simulated deposit, in [currency] *)
    ; payment : Money.Amount.t (** paid out, in [currency]; less than [deposit] *)
    ; timeout : Time_ns.Span.t (** for each awaited event or state *)
    ; poll_interval : Time_ns.Span.t
    ; currency : Money.Currency.t (** of the accounts the scenarios open *)
    ; rail : Rail.t (** for deposits, fee quotes and payments *)
    ; payee : string option
    (** the payee's destination as {!Payments_core.Beneficiary.create} reads it for
        [rail]; [None] means [payee_iban] *)
    }

  (** A synthetic person, [Fake_provider.sandbox_code], a public example IBAN, EUR 100 in
      and EUR 30 out over SCT Inst, 10 second timeouts polled every 50 ms. *)
  val default : run_id:string -> t

  (** {!default} in GBP over Faster Payments: a synthetic UK resident, GBP 100 in and GBP
      30 out, paid to sort code [99-00-00] (which no bank uses). Accounts must show a sort
      code and account number (or a GB IBAN). *)
  val gbp : run_id:string -> t

  (** [payee], else [payee_iban]. *)
  val payee : t -> string
end

module Make (P : Provider.S) (_ : Sandbox.S with type t = P.t) : sig
  type scenario =
    { name : string
    ; run : P.t -> unit Or_error.t Deferred.t
    }

  val scenarios : Config.t -> scenario list

  (** Runs every scenario in order; each result is labelled with its name. *)
  val run_all : Config.t -> P.t -> (string * unit Or_error.t) list Deferred.t
end
