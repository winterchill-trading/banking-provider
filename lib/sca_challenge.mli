(** A strong customer authentication challenge issued by the provider for one operation.

    Providers that move money under their own licence run SCA themselves: the operation
    stops until the customer answers a code (SMS OTP, authenticator app), and the
    provider binds the code to the operation's amount and payee. The challenge says what
    it is for; {!Provider.S.confirm_sca} answers it, and the operation then proceeds (its
    result arrives as an event or a status query). The code itself is a {!Sensitive.t}
    and is never kept. *)

open! Core
open Payments_core

module Purpose : sig
  type t =
    | Transfer of Transfer.Id.t
    | Swap of Swap.Id.t
    | Standing_order of Standing_order_ref.t
    | Card_details of Card_core.Ids.Card_id.t (** revealing a card's number through the provider *)
  [@@deriving sexp, compare, equal]
end

type t =
  { id : Sca.Id.t
  ; purpose : Purpose.t
  ; factors : Sca.Kind.t list
  ; expires_at : Utc_time.t
  ; attempts_left : int
  }
[@@deriving sexp, compare, equal]

module Result : sig
  type t =
    | Accepted (** the operation proceeds *)
    | Wrong_code of { attempts_left : int } (** never says which factor was wrong *)
    | Failed of Sca.Failure.t (** expired, too many attempts or cancelled: start again *)
  [@@deriving sexp, compare, equal]
end

(** The answer to a request that may need SCA before it takes effect. *)
module Or_challenge : sig
  type nonrec 'a t =
    | Done of 'a
    | Challenge of t
  [@@deriving sexp, compare, equal]
end
