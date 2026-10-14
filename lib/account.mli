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
    | Us_account of Us_account.Stable.V1.t
    (** a US routing and account number, for ACH, RTP and Fedwire *)
    | Local of
        { scheme : string
        (** names the format, lower snake case: [kg] (bank code and account number),
            [ch_qr_iban] (the QR-IBAN for Swiss QR-bill payments), ... *)
        ; fields : (string * string) list
        (** in display order; names are lower snake case ([bank_code], [account_number],
            [qr_iban]) *)
        }
    (** Details in a domestic format the other variants do not cover, for markets with no
        IBAN (a bank code and account number) or with a second identifier next to the IBAN
        (a QR-IBAN). Several local addresses may sit on one account. *)
  [@@deriving sexp, compare, equal]

  (** [bin_io] on [t] is {!Stable.V1}, so records that embed an address (events,
      {!Account.t}) keep their format and digests. *)
  include Binable.S with type t := t

  module Stable : sig
    module V3 : sig
      type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
    end

    module V2 : sig
      (** The five addresses before [Local]; writing a [Local] address raises. *)
      type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
    end

    module V1 : sig
      (** The first three addresses' format; writing a [Uk_account], a [Us_account], a
          [Local] address or a crypto address on a newer network raises. *)
      type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
    end
  end

  (** The [scheme] names of the [Local] formats this library knows. An adapter may use
      others; these keep the common ones spelled one way. *)
  module Local_scheme : sig
    (** Kyrgyzstan: fields [bank_code] (six digits) and [account_number] (sixteen). *)
    val kg : string

    (** Switzerland: field [qr_iban], the QR-IBAN that QR-bills name next to the account's
        ordinary IBAN. *)
    val ch_qr_iban : string
  end

  (** The details as a customer reads them, one line each: [IBAN DE89 3704 ...] and
      [BIC ...]; [Sort code 99-00-00] and [Account number ...]; [Routing number ...],
      [Account number ...] and the account type; the network and address of a crypto
      address; and for [Local], one [Label value] line per field, the label made from the
      field name ([bank_code] reads [Bank code], [qr_iban] reads [QR-IBAN], and
      IBAN-shaped values are grouped in fours). Plain English labels, for statements, logs
      and the demo; an app translates its own. *)
  val to_display_lines : t -> string list
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
    (** Addresses in {!Address.Stable.V2}: an account with a [Local] address raises. *)
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

  module V3 : sig
    type nonrec t = t =
      { id : Account_ref.Stable.V1.t
      ; customer : Customer_ref.Stable.V1.t
      ; currency : Money.Currency.Stable.V1.t
      ; status : Ledger.Account_status.Stable.V1.t
      ; addresses : Address.Stable.V3.t list
      ; opened_at : Utc_time.Stable.V1.t
      }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

val iban : t -> Iban.t option
val crypto_address : t -> Crypto_address.t option

(** The sort code and account number, from a [Uk_account] address or a GB IBAN. *)
val uk_account : t -> Uk_account.t option

(** The routing and account number of a [Us_account] address. *)
val us_account : t -> Us_account.t option

(** The first [Local] address with this [scheme], as its fields. *)
val local : t -> scheme:string -> (string * string) list option

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
