open! Core
module Card = Card_core.Card
module Ids = Card_core.Ids
module Limits = Card_core.Limits
module Masked_pan = Card_core.Masked_pan

type t =
  { id : Ids.Card_id.t
  ; customer : Customer_ref.t
  ; account : Account_ref.t
  ; kind : Card.Kind.t
  ; status : Card.Status.t
  ; masked_pan : Masked_pan.t option
  ; limits : Limits.t
  ; created_at : Payments_core.Utc_time.t
  }
[@@deriving sexp_of, compare, equal]
