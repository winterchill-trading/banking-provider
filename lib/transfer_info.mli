(** A transfer as the provider currently sees it, from a status query. *)

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

module Fee_quote : sig
  type t =
    { rail : Rail.t
    ; amount : Money.Amount.t (** what the counterparty receives *)
    ; fee : Money.Amount.t
    ; total : Money.Amount.t (** debited from the account *)
    }
  [@@deriving sexp, compare, equal]
end
