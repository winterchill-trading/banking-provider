(** An account or wallet at the provider: one currency, owned by one customer.

    Fiat accounts get an IBAN (or, in the UK, a sort code and account number) and crypto
    wallets a deposit address once {e enriched}; some providers assign them at once,
    others on request or minutes later, so [addresses] may be empty right after opening. *)

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
    | Uk_account of Uk_account.Stable.V1.t
    (** a UK sort code and account number, for Faster Payments, CHAPS and Bacs *)
  [@@deriving sexp, compare, equal]

  (** [bin_io] on [t] is {!Stable.V1}, so records that embed an address (events,
      {!Account.t}) keep their format and digests. *)
  include Binable.S with type t := t

  module Stable : sig
    module V2 : sig
      type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
    end

    module V1 : sig
      (** The first three addresses' format; writing a [Uk_account] raises. *)
      type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
    end
  end
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

(** [bin_io] on [t] is {!Stable.V1}. *)
module Stable : sig
  module V1 : sig
    (** Addresses in {!Address.Stable.V1}: an account with UK details raises. *)
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
  end

  module V2 : sig
    type nonrec t = t =
      { id : Account_ref.Stable.V1.t
      ; customer : Customer_ref.Stable.V1.t
      ; currency : Money.Currency.Stable.V1.t
      ; status : Ledger.Account_status.Stable.V1.t
      ; addresses : Address.Stable.V2.t list
      ; opened_at : Utc_time.Stable.V1.t
      }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

val iban : t -> Iban.t option
val crypto_address : t -> Crypto_address.t option

(** The sort code and account number, from a [Uk_account] address or a GB IBAN. *)
val uk_account : t -> Uk_account.t option

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
