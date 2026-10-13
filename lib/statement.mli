(** An account statement as the provider produces it: lines on the customer's side (a
    credit to the customer is positive) with the running balance. *)

open! Core
open Payments_core

module Line : sig
  type t =
    { at : Utc_time.t (** value time *)
    ; amount : Money.Amount.t (** signed: positive in, negative out *)
    ; code : string (** what moved money, e.g. [DEPOSIT], [FEE], [CARD_SETTLEMENT] *)
    ; reference : string (** a transfer, swap or card transaction id *)
    ; balance : Money.Amount.t (** after this line *)
    }
  [@@deriving sexp, compare, equal]
end

type t =
  { account : Account_ref.t
  ; currency : Money.Currency.t
  ; from : Utc_time.t (** inclusive *)
  ; until : Utc_time.t (** exclusive *)
  ; opening : Money.Amount.t
  ; lines : Line.t list
  ; closing : Money.Amount.t
  }
[@@deriving sexp, compare, equal]

(** [closing = opening + sum of lines], and each line's balance follows the previous. *)
val check : t -> unit Or_error.t
