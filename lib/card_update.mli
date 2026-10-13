(** Card activity as a provider reports it: status changes and the scheme messages of an
    authorization's life (request, advice, reversal, clearing, expiry), in card-core's
    types.

    These are messages, not state: card-core's state machines ({!Card_core.Authorization},
    {!Card_core.Settlement}) decide what they mean for a card and its holds. A clearing
    may be partial, repeated, above the authorization or without one; a refund is a credit
    clearing, never an edit of the purchase. Merchant names pass {!Card_core.Pan_guard}
    ({!Card_core.Merchant.create}) before they get here. *)

open! Core
module Card := Card_core.Card
module Ids := Card_core.Ids
module Merchant := Card_core.Merchant
module Entry_mode := Card_core.Entry_mode
module Response_code := Card_core.Response_code
module Settlement := Card_core.Settlement

module Decided_by : sig
  (** {!Card_core.Authorization.Decided_by.t} with a binary form, for persisted events. *)
  type t = Card_core.Authorization.Decided_by.t =
    | Us (** we answered the provider's real-time request *)
    | Stand_in (** the scheme answered for us: an advice *)
    | Provider_default (** the provider applied its own rules *)
  [@@deriving bin_io, sexp, compare, equal]
end

module Authorization : sig
  type t =
    { auth : Ids.Auth_id.Stable.V1.t
    ; network_txn : Ids.Network_txn_id.Stable.V1.t
    ; amount : Money.Amount.Stable.V1.t (** requested, in the card's billing currency *)
    ; approved : Money.Amount.Stable.V1.t (** zero when declined; less when partial *)
    ; merchant : Merchant.Stable.V1.t (** with the amount in the merchant's currency *)
    ; entry_mode : Entry_mode.Stable.V1.t
    ; response : Response_code.Stable.V1.t
    ; decided_by : Decided_by.t
    }
  [@@deriving bin_io, sexp, compare, equal]
end

type t =
  | Status_changed of Card.Status.Stable.V1.t
  | Auth_request of Authorization.t (** answered in real time *)
  | Auth_advice of Authorization.t (** decided elsewhere; recorded, not decided *)
  | Reversal of
      { auth : Ids.Auth_id.Stable.V1.t
      ; amount : Money.Amount.Stable.V1.t (** what was released *)
      }
  | Clearing of Settlement.Clearing.Stable.V1.t
  (** a debit clearing, or a refund when its direction is [Credit] *)
  | Expiry of { auth : Ids.Auth_id.Stable.V1.t } (** the hold lapsed without a clearing *)
[@@deriving bin_io, sexp, compare, equal]
