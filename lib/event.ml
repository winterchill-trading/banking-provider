open! Core
open Payments_core

module Kyc_update = struct
  type t =
    | Step of
        { step : Kyc_core.Verification.Step.Stable.V1.t
        ; state : Kyc_core.Verification.State.Stable.V1.t
        }
    | Status of Kyc_core.Status.Transition.Stable.V1.t
  [@@deriving bin_io, sexp, compare, equal]
end

module Kind = struct
  type t =
    | Kyc of
        { customer : Customer_ref.Stable.V1.t
        ; update : Kyc_update.t
        }
    | Account_opened of Account.t
    | Account_updated of Account.t
    | Incoming_transfer of
        { account : Account_ref.Stable.V1.t
        ; transfer : Transfer.Id.Stable.V1.t
        ; provider_ref : string
        ; rail : Rail.Stable.V1.t
        ; amount : Money.Amount.Stable.V1.t
        ; fee : Money.Amount.Stable.V1.t
        ; from : Transfer.Counterparty.t
        ; reference : string
        ; details : Transfer.Details.t
        ; settled : bool
        }
    | Transfer of
        { transfer : Transfer.Id.Stable.V1.t
        ; provider_ref : string
        ; update : Transfer_update.t
        }
    | Payee_check of
        { beneficiary : Beneficiary.Id.Stable.V1.t
        ; result : Beneficiary.Payee_check.t
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
  [@@deriving bin_io, sexp, compare, equal, variants]

  module Stable = struct
    module V1 = struct
      type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
    end

    module V2 = struct
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
  end

  let name t = Variants.to_name t
end

module T = struct
  type t =
    { id : Event_id.Stable.V1.t
    ; at : Utc_time.Stable.V1.t
    ; kind : Kind.t
    }
  [@@deriving bin_io, sexp, compare, equal]
end

include T

module Stable = struct
  module V1 = T

  module V2 = struct
    type t = T.t =
      { id : Event_id.Stable.V1.t
      ; at : Utc_time.Stable.V1.t
      ; kind : Kind.Stable.V2.t
      }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

let incoming_transfer_id ~provider_ref = Transfer.Id.of_string ("in:" ^ provider_ref)
let booking_event_id t = Event_id.to_string t.id

let to_kyc_event t ~customer_id ~provider : Kyc_core.Event.t option =
  match t.kind with
  | Kyc { customer = _; update } ->
    let kind : Kyc_core.Event.Kind.t =
      match update with
      | Step { step; state } -> Step_changed { step; state }
      | Status transition -> Status_changed transition
    in
    Some
      { id = Kyc_core.Event_id.of_string (Event_id.to_string t.id)
      ; customer_id
      ; at = t.at
      ; actor = Provider provider
      ; note = None
      ; kind
      }
  | _ -> None
;;

let incoming_transfer t ~account =
  match t.kind with
  | Incoming_transfer
      { account = _
      ; transfer
      ; provider_ref
      ; rail
      ; amount
      ; fee
      ; from
      ; reference
      ; details
      ; settled
      } ->
    Some
      (Transfer.incoming
         ~id:transfer
         ~rail
         ~account
         ~from
         ~amount
         ~fee
         ~reference
         ~details
         ~provider_ref
         ~status:(if settled then Settled else Pending)
         ~now:t.at
         ())
  | _ -> None
;;
