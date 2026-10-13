(** Card activity as a provider reports it: status changes and the scheme messages of an
    authorization's life (request, advice, reversal, clearing, refund, expiry).

    These are messages, not state: card-core's state machines decide what they mean for
    a card and its holds. Clearings may be partial, repeated, above the authorization or
    without one; a refund is a new credit, never an edit of the purchase. Merchant names
    pass {!Card_core.Pan_guard} before they get here. *)

open! Core
module Card := Card_core.Card
module Ids := Card_core.Ids
module Mcc := Card_core.Mcc
module Country := Card_core.Country
module Entry_mode := Card_core.Entry_mode
module Response_code := Card_core.Response_code

module Status : sig
  (** {!Card_core.Card.Status.t} with a binary form, for persisted events. *)
  type t = Card.Status.t [@@deriving bin_io, sexp, compare, equal]
end

module Merchant : sig
  type t =
    { name : string
    ; mcc : Mcc.Stable.V1.t
    ; country : Country.Stable.V1.t
    }
  [@@deriving bin_io, sexp, compare, equal]
end

module Decided_by : sig
  type t =
    | Us (** we answered the provider's real-time request *)
    | Stand_in (** the scheme or processor answered for us: an advice *)
    | Provider_default (** the provider applied its own rules *)
  [@@deriving bin_io, sexp, compare, equal]
end

module Authorization : sig
  type t =
    { auth : Ids.Auth_id.Stable.V1.t
    ; network_txn : Ids.Network_txn_id.Stable.V1.t
    ; amount : Money.Amount.Stable.V1.t (** in the card's billing currency *)
    ; merchant_amount : Money.Amount.Stable.V1.t (** as the merchant charged it *)
    ; merchant : Merchant.t
    ; entry_mode : Entry_mode.Stable.V1.t
    ; response : Response_code.Stable.V1.t
    ; decided_by : Decided_by.t
    }
  [@@deriving bin_io, sexp, compare, equal]
end

type t =
  | Status_changed of Status.t
  | Auth_request of Authorization.t (** answered in real time *)
  | Auth_advice of Authorization.t (** decided elsewhere; recorded, not decided *)
  | Reversal of
      { auth : Ids.Auth_id.Stable.V1.t
      ; amount : Money.Amount.Stable.V1.t option (** [None]: the whole remainder *)
      }
  | Clearing of
      { clearing : Ids.Clearing_id.Stable.V1.t
      ; auth : Ids.Auth_id.Stable.V1.t option (** [None]: a clearing without an auth *)
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
  | Expiry of { auth : Ids.Auth_id.Stable.V1.t } (** the hold lapsed without a clearing *)
[@@deriving bin_io, sexp, compare, equal]
