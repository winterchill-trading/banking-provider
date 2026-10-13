open! Core
open Payments_core

module Purpose = struct
  type t =
    | Transfer of Transfer.Id.t
    | Swap of Swap.Id.t
    | Standing_order of Standing_order_ref.t
    | Card_details of Card_ref.t
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

module Result = struct
  type t =
    | Accepted
    | Wrong_code of { attempts_left : int }
    | Failed of Sca.Failure.t
  [@@deriving sexp, compare, equal]
end

module Or_challenge = struct
  type nonrec 'a t =
    | Done of 'a
    | Challenge of t
  [@@deriving sexp, compare, equal]
end
