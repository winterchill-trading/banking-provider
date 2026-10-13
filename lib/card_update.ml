open! Core
module Card = Card_core.Card
module Ids = Card_core.Ids
module Merchant = Card_core.Merchant
module Entry_mode = Card_core.Entry_mode
module Response_code = Card_core.Response_code
module Settlement = Card_core.Settlement

module Decided_by = struct
  type t = Card_core.Authorization.Decided_by.t =
    | Us
    | Stand_in
    | Provider_default
  [@@deriving bin_io, sexp, compare, equal]
end

module Authorization = struct
  type t =
    { auth : Ids.Auth_id.Stable.V1.t
    ; network_txn : Ids.Network_txn_id.Stable.V1.t
    ; amount : Money.Amount.Stable.V1.t
    ; approved : Money.Amount.Stable.V1.t
    ; merchant : Merchant.Stable.V1.t
    ; entry_mode : Entry_mode.Stable.V1.t
    ; response : Response_code.Stable.V1.t
    ; decided_by : Decided_by.t
    }
  [@@deriving bin_io, sexp, compare, equal]
end

type t =
  | Status_changed of Card.Status.Stable.V1.t
  | Auth_request of Authorization.t
  | Auth_advice of Authorization.t
  | Reversal of
      { auth : Ids.Auth_id.Stable.V1.t
      ; amount : Money.Amount.Stable.V1.t
      }
  | Clearing of Settlement.Clearing.Stable.V1.t
  | Expiry of { auth : Ids.Auth_id.Stable.V1.t }
[@@deriving bin_io, sexp, compare, equal]
