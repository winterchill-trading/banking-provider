open! Core
open Payments_core

module Stable = struct
  module V1 = struct
    type t =
      { result : Beneficiary.Payee_check.Stable.V2.t
      ; account_currency : Money.Currency.Stable.V1.t option [@sexp.option]
      }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

type t = Stable.V1.t =
  { result : Beneficiary.Payee_check.t
  ; account_currency : Money.Currency.t option [@sexp.option]
  }
[@@deriving sexp, compare, equal]

let create ?account_currency result = { result; account_currency }
