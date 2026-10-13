open! Core
open Card_core

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
