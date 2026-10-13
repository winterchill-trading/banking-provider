(** Scenarios every {!Provider.S} implementation must pass.

    The fake passes them in this repository's tests; an adapter for a real provider runs
    the same functor against its sandbox (behind an environment gate, since that needs
    credentials). The scenarios rely only on the contract in {!Provider.S}: results are
    awaited as events or by polling, within [timeout], so a sandbox that provisions an
    IBAN minutes later or settles a payment asynchronously still passes. Every customer id
    starts with [run_id], so reruns against a shared sandbox do not collide.

    Each scenario returns [Ok ()] or an error saying what did not hold. *)

open! Core
open Async_kernel

module Config : sig
  type t =
    { run_id : string (** prefix of every customer id, e.g. a timestamp *)
    ; person : Kyc_core.Person.t (** synthetic; sent to the provider as the customer *)
    ; sca_code : Sensitive.t (** what the sandbox accepts as an OTP *)
    ; payee_iban : string (** a valid SEPA IBAN the sandbox may pay *)
    ; deposit : Money.Amount.t (** EUR credited by the simulated deposit *)
    ; payment : Money.Amount.t (** EUR paid out; less than [deposit] *)
    ; timeout : Time_ns.Span.t (** for each awaited event or state *)
    ; poll_interval : Time_ns.Span.t
    }

  (** A synthetic person, [Fake_provider.sandbox_code], a public example IBAN, EUR 100 in
      and EUR 30 out, 10 second timeouts polled every 50 ms. *)
  val default : run_id:string -> t
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
