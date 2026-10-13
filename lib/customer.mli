(** A customer at the provider, and its KYC state as the provider reports it.

    The provider's KYC is one input to our own case ({!Kyc_core.Kyc_case}): it says which
    verification steps passed and whether the provider approved the customer. Risk bands,
    screening reviews and alerts stay in our case and are never sent to the provider. *)

open! Core
open Payments_core

type t =
  { id : Customer_ref.t
  ; customer_id : Kyc_core.Customer_id.t (** ours, sent as the provider's external id *)
  ; created_at : Utc_time.t
  }
[@@deriving sexp, compare, equal]

module Kyc_status : sig
  type t =
    { customer : Customer_ref.t
    ; status : Kyc_core.Status.t
    ; tier : Kyc_core.Tier.t
    (** by {!Kyc_core.Tier.Rules.default} over the verified steps *)
    ; steps : (Kyc_core.Verification.Step.t * Kyc_core.Verification.State.t) list
    }
  [@@deriving sexp, compare, equal]

  (** Status [Created], tier [T0], every step [Pending]. *)
  val initial : Customer_ref.t -> t

  (** Re-derives [tier] from the steps. *)
  val with_step : t -> Kyc_core.Verification.Step.t -> Kyc_core.Verification.State.t -> t
end

module Verification_session : sig
  (** What starting a verification step gives back. *)
  type t =
    | Code_sent of
        { step : Kyc_core.Verification.Step.t
        ; expires_at : Utc_time.t
        } (** e-mail or SMS code; complete it with the code the customer received *)
    | Hosted of
        { step : Kyc_core.Verification.Step.t
        ; token : Sensitive.t (** for the provider's hosted document or liveness flow *)
        ; expires_at : Utc_time.t
        } (** the result arrives later as an event *)
  [@@deriving sexp_of]

  val step : t -> Kyc_core.Verification.Step.t
end
