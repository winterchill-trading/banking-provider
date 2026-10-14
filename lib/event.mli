(** Everything a provider tells us asynchronously, normalized.

    Each event carries the provider's own event id ({!Event_id}), which is the inbox key:
    providers deliver at least once and in no guaranteed order, so a consumer applies an
    id once ({!Inbox}) and lets the state machines ({!Transfer_update.apply},
    {!Kyc_core.Kyc_case.apply}, card-core) ignore reports that were overtaken. Ledger
    entries booked for an event use {!booking_event_id} in their idempotency keys, so a
    replayed event cannot book twice either.

    [at] is when the provider says it happened, not when we received it; do not order
    events by it. *)

open! Core
open Payments_core

module Kyc_update : sig
  type t =
    | Step of
        { step : Kyc_core.Verification.Step.Stable.V1.t
        ; state : Kyc_core.Verification.State.Stable.V1.t
        }
    | Status of Kyc_core.Status.Transition.Stable.V1.t
  [@@deriving bin_io, sexp, compare, equal]
end

module Kind : sig
  type t =
    | Kyc of
        { customer : Customer_ref.Stable.V1.t
        ; update : Kyc_update.t
        }
    | Account_opened of Account.t
    | Account_updated of Account.t (** enriched with an IBAN or address, frozen, closed *)
    | Incoming_transfer of
        { account : Account_ref.Stable.V1.t
        ; transfer : Transfer.Id.Stable.V1.t
        (** {!incoming_transfer_id} of [provider_ref] *)
        ; provider_ref : string
        ; rail : Rail.Stable.V1.t
        ; amount : Money.Amount.Stable.V1.t
        ; fee : Money.Amount.Stable.V1.t
        ; from : Transfer.Counterparty.t
        ; reference : string
        ; details : Transfer.Details.t
        ; settled : bool (** [false]: pending, e.g. waiting for confirmations *)
        } (** a deposit; later changes arrive as [Transfer] *)
    | Transfer of
        { transfer : Transfer.Id.Stable.V1.t
        ; provider_ref : string
        ; update : Transfer_update.t
        }
    | Payee_check of
        { beneficiary : Beneficiary.Id.Stable.V1.t
        ; result : Beneficiary.Payee_check.t
        } (** a payee-name check (SEPA Verification of Payee, UK Confirmation of Payee) *)
    | Swap_executed of
        { swap : Swap.Id.Stable.V1.t
        ; sell : Money.Amount.Stable.V1.t
        ; fee : Money.Amount.Stable.V1.t
        ; buy : Money.Amount.Stable.V1.t
        }
    | Swap_failed of
        { swap : Swap.Id.Stable.V1.t
        ; reason : string
        }
    | Card of
        { card : Card_core.Ids.Card_id.Stable.V1.t
        ; update : Card_update.t
        }
    | Standing_order_run of
        { order : Standing_order_ref.Stable.V1.t
        ; run_date : Date.Stable.V1.t
        ; transfer : Transfer.Id.Stable.V1.t
        }
    | Ping (** a test delivery *)
  [@@deriving bin_io, sexp, compare, equal]

  (** [bin_io] on [t] is {!Stable.V1}. *)
  module Stable : sig
    module V1 : sig
      (** UK rails, accounts and details raise; newer payee check results are written as
          [Not_possible]. *)
      type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
    end

    (** Accounts in {!Account.Stable.V2}: an account with a [Local] address raises. *)
    module V2 : sig
      type nonrec t = t =
        | Kyc of
            { customer : Customer_ref.Stable.V1.t
            ; update : Kyc_update.t
            }
        | Account_opened of Account.Stable.V2.t
        | Account_updated of Account.Stable.V2.t
        | Incoming_transfer of
            { account : Account_ref.Stable.V1.t
            ; transfer : Transfer.Id.Stable.V1.t
            ; provider_ref : string
            ; rail : Rail.Stable.V2.t
            ; amount : Money.Amount.Stable.V1.t
            ; fee : Money.Amount.Stable.V1.t
            ; from : Transfer.Counterparty.Stable.V2.t
            ; reference : string
            ; details : Transfer.Details.Stable.V2.t
            ; settled : bool
            }
        | Transfer of
            { transfer : Transfer.Id.Stable.V1.t
            ; provider_ref : string
            ; update : Transfer_update.t
            }
        | Payee_check of
            { beneficiary : Beneficiary.Id.Stable.V1.t
            ; result : Beneficiary.Payee_check.Stable.V2.t
            }
        | Swap_executed of
            { swap : Swap.Id.Stable.V1.t
            ; sell : Money.Amount.Stable.V1.t
            ; fee : Money.Amount.Stable.V1.t
            ; buy : Money.Amount.Stable.V1.t
            }
        | Swap_failed of
            { swap : Swap.Id.Stable.V1.t
            ; reason : string
            }
        | Card of
            { card : Card_core.Ids.Card_id.Stable.V1.t
            ; update : Card_update.t
            }
        | Standing_order_run of
            { order : Standing_order_ref.Stable.V1.t
            ; run_date : Date.Stable.V1.t
            ; transfer : Transfer.Id.Stable.V1.t
            }
        | Ping
      [@@deriving bin_io, sexp, compare, equal]
    end

    (** Accounts in {!Account.Stable.V3}, which can hold [Local] addresses. *)
    module V3 : sig
      type nonrec t = t =
        | Kyc of
            { customer : Customer_ref.Stable.V1.t
            ; update : Kyc_update.t
            }
        | Account_opened of Account.Stable.V3.t
        | Account_updated of Account.Stable.V3.t
        | Incoming_transfer of
            { account : Account_ref.Stable.V1.t
            ; transfer : Transfer.Id.Stable.V1.t
            ; provider_ref : string
            ; rail : Rail.Stable.V2.t
            ; amount : Money.Amount.Stable.V1.t
            ; fee : Money.Amount.Stable.V1.t
            ; from : Transfer.Counterparty.Stable.V2.t
            ; reference : string
            ; details : Transfer.Details.Stable.V2.t
            ; settled : bool
            }
        | Transfer of
            { transfer : Transfer.Id.Stable.V1.t
            ; provider_ref : string
            ; update : Transfer_update.t
            }
        | Payee_check of
            { beneficiary : Beneficiary.Id.Stable.V1.t
            ; result : Beneficiary.Payee_check.Stable.V2.t
            }
        | Swap_executed of
            { swap : Swap.Id.Stable.V1.t
            ; sell : Money.Amount.Stable.V1.t
            ; fee : Money.Amount.Stable.V1.t
            ; buy : Money.Amount.Stable.V1.t
            }
        | Swap_failed of
            { swap : Swap.Id.Stable.V1.t
            ; reason : string
            }
        | Card of
            { card : Card_core.Ids.Card_id.Stable.V1.t
            ; update : Card_update.t
            }
        | Standing_order_run of
            { order : Standing_order_ref.Stable.V1.t
            ; run_date : Date.Stable.V1.t
            ; transfer : Transfer.Id.Stable.V1.t
            }
        | Ping
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  (** The constructor name, for logs and metrics. *)
  val name : t -> string
end

type t =
  { id : Event_id.Stable.V1.t
  ; at : Utc_time.Stable.V1.t
  ; kind : Kind.t
  }
[@@deriving bin_io, sexp, compare, equal]

module Stable : sig
  module V1 : sig
    (** The format before the UK rails (digest [c2a5e9ee…]); see {!Kind.Stable.V1}. *)
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
  end

  (** Rails, accounts, counterparties, details and payee checks in their V2 formats: use
      this to persist events that can be about UK payments. *)
  module V2 : sig
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
  end

  (** {!V2} with accounts in {!Account.Stable.V3}: use this to persist events whose
      accounts can carry [Local] addresses. *)
  module V3 : sig
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
  end
end

(** Our id for a deposit the provider reports as [provider_ref]: [in:<provider_ref>], so
    every report about it lands on the same transfer. *)
val incoming_transfer_id : provider_ref:string -> Transfer.Id.t

(** The [event_id] to give {!Payments_core.Booking} and the ledger: the provider's event
    id. *)
val booking_event_id : t -> string

(** The kyc-core event for a [Kyc] event, applied to our case for [customer_id]; the actor
    is [Provider provider]. [None] for other kinds. Provider events carry no personal
    data, so the application opens the case itself ([Opened person]) before applying
    these. *)
val to_kyc_event
  :  t
  -> customer_id:Kyc_core.Customer_id.t
  -> provider:string
  -> Kyc_core.Event.t option

(** The [Transfer.t] for an [Incoming_transfer] event, credited to our ledger account
    [account]: [Settled] or [Pending] as reported. [None] for other kinds. *)
val incoming_transfer : t -> account:Ledger.Account_id.t -> Transfer.t Or_error.t option
