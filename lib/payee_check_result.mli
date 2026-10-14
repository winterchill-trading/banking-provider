(** A payee check answer with what the receiving bank told about the account besides the
    name: today its currency, when the provider knows it. A payment in another currency
    than the receiving account's is often converted at the receiving bank's rate, so an
    app can warn before sending. *)

open! Core
open Payments_core

type t =
  { result : Beneficiary.Payee_check.t
  ; account_currency : Money.Currency.t option
  (** the receiving account's currency; [None] when the provider does not know it *)
  }
[@@deriving sexp, compare, equal]

(** [{ result; account_currency }]; [account_currency] defaults to [None]. *)
val create : ?account_currency:Money.Currency.t -> Beneficiary.Payee_check.t -> t

module Stable : sig
  module V1 : sig
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
  end
end
