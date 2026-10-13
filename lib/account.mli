(** An account or wallet at the provider: one currency, owned by one customer.

    Fiat accounts get an IBAN and crypto wallets a deposit address once {e enriched};
    some providers assign them at once, others on request or minutes later, so
    [addresses] may be empty right after opening. *)

open! Core
open Payments_core

module Address : sig
  type t =
    | Iban of
        { iban : Iban.Stable.V1.t
        ; bic : Bic.Stable.V1.t option
        }
    | Crypto of
        { address : Crypto_address.Stable.V1.t
        ; memo : string option (** destination tag, where the chain needs one *)
        }
    | Lightning_node of { node_id : string }
    (** Lightning receives by invoice; the node id says where invoices come from *)
  [@@deriving bin_io, sexp, compare, equal]
end

type t =
  { id : Account_ref.Stable.V1.t
  ; customer : Customer_ref.Stable.V1.t
  ; currency : Money.Currency.Stable.V1.t
  ; status : Ledger.Account_status.Stable.V1.t
  ; addresses : Address.t list
  ; opened_at : Utc_time.Stable.V1.t
  }
[@@deriving bin_io, sexp, compare, equal]

val iban : t -> Iban.t option
val crypto_address : t -> Crypto_address.t option

module Balance : sig
  (** On the customer's side: a deposit makes [posted] grow. [available = posted - held],
      where [held] covers outgoing payments and card authorizations not yet settled. *)
  type t =
    { account : Account_ref.t
    ; available : Money.Amount.t
    ; held : Money.Amount.t
    ; posted : Money.Amount.t
    ; as_of : Utc_time.t
    }
  [@@deriving sexp, compare, equal]
end
