open! Core
open Payments_core

type t =
  { transfer : Transfer.Id.t
  ; provider_ref : string
  ; status : Transfer.Status.t
  ; fee : Money.Amount.t
  ; details : Transfer.Details.t
  ; updated_at : Utc_time.t
  }
[@@deriving sexp, compare, equal]

module Fee_quote = struct
  type t =
    { rail : Rail.t
    ; amount : Money.Amount.t
    ; fee : Money.Amount.t
    ; total : Money.Amount.t
    }
  [@@deriving sexp, compare, equal]
end
