open! Core
module Card = Card_core.Card
module Ids = Card_core.Ids
module Mcc = Card_core.Mcc
module Country = Card_core.Country
module Entry_mode = Card_core.Entry_mode
module Response_code = Card_core.Response_code

module Status = struct
  module Wire = struct
    (* Same constructors in the same order as [Card_core.Card.Status.t]; the conversions
       below are total matches, so adding a status there breaks the build here. *)
    type t =
      | Requested
      | Active
      | Frozen
      | Blocked
      | Expired
      | Destroyed
    [@@deriving bin_io]
  end

  type t = Card.Status.t [@@deriving sexp, compare, equal]

  include
    Binable.Of_binable_without_uuid [@alert "-legacy"]
      (Wire)
      (struct
        type nonrec t = t

        let to_binable : t -> Wire.t = function
          | Requested -> Requested
          | Active -> Active
          | Frozen -> Frozen
          | Blocked -> Blocked
          | Expired -> Expired
          | Destroyed -> Destroyed
        ;;

        let of_binable : Wire.t -> t = function
          | Requested -> Requested
          | Active -> Active
          | Frozen -> Frozen
          | Blocked -> Blocked
          | Expired -> Expired
          | Destroyed -> Destroyed
        ;;
      end)
end

module Merchant = struct
  type t =
    { name : string
    ; mcc : Mcc.Stable.V1.t
    ; country : Country.Stable.V1.t
    }
  [@@deriving bin_io, sexp, compare, equal]
end

module Decided_by = struct
  type t =
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
    ; merchant_amount : Money.Amount.Stable.V1.t
    ; merchant : Merchant.t
    ; entry_mode : Entry_mode.Stable.V1.t
    ; response : Response_code.Stable.V1.t
    ; decided_by : Decided_by.t
    }
  [@@deriving bin_io, sexp, compare, equal]
end

type t =
  | Status_changed of Status.t
  | Auth_request of Authorization.t
  | Auth_advice of Authorization.t
  | Reversal of
      { auth : Ids.Auth_id.Stable.V1.t
      ; amount : Money.Amount.Stable.V1.t option
      }
  | Clearing of
      { clearing : Ids.Clearing_id.Stable.V1.t
      ; auth : Ids.Auth_id.Stable.V1.t option
      ; network_txn : Ids.Network_txn_id.Stable.V1.t
      ; amount : Money.Amount.Stable.V1.t
      ; merchant_amount : Money.Amount.Stable.V1.t
      ; merchant : Merchant.t
      }
  | Refund of
      { clearing : Ids.Clearing_id.Stable.V1.t
      ; network_txn : Ids.Network_txn_id.Stable.V1.t option
      ; amount : Money.Amount.Stable.V1.t
      ; merchant : Merchant.t
      }
  | Expiry of { auth : Ids.Auth_id.Stable.V1.t }
[@@deriving bin_io, sexp, compare, equal]
