(** A card as the provider shows it: ids on the provider's side, the masked number once
    issued, status and limits. Never a full card number, CVV or PIN; those are shown to
    the cardholder only through the provider's hosted component (see
    {!Provider.S.card_details_token}). *)

open! Core
module Card := Card_core.Card
module Ids := Card_core.Ids
module Limits := Card_core.Limits
module Masked_pan := Card_core.Masked_pan

type t =
  { id : Ids.Card_id.t
  ; customer : Customer_ref.t
  ; account : Account_ref.t (** the funding account *)
  ; kind : Card.Kind.t
  ; status : Card.Status.t
  ; masked_pan : Masked_pan.t option
  ; limits : Limits.t
  ; created_at : Payments_core.Utc_time.t
  }
[@@deriving sexp_of, compare, equal]
