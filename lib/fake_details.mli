(** Deterministic, well-formed bank details for fakes, fixtures and demos, derived from a
    key: the same key gives the same details on every run and every machine, and different
    keys almost always give different ones.

    Each market has one fake bank, as a provider would: its bank identifier is fixed and
    the account number comes from a SHA-256 hash of the key. The identifiers are chosen so
    that they pass the format and checksum rules, not looked up in any directory; do not
    send money to them. Two keys can, rarely, hash to the same account number (one in ten
    billion for a ten-digit number), which a fake can live with.

    - EU: an IBAN with valid check digits ({!eu_iban}); German by default.
    - GB: sort code [99-00-00], which no bank uses, and an account number that passes the
      modulus check for its sort code where the weights allow ({!uk_account}).
    - US: routing number [123456780] (valid check digit) and a ten-digit account number
      ({!us_account}).
    - KG: a {!Account.Address.Local} with a bank code and a sixteen-digit account number
      ({!val-kg}).
    - CH: an IBAN and the matching QR-IBAN ({!val-ch}). *)

open! Core
open Payments_core

(** {2 EU} *)

(** An IBAN for [country] (default [DE]) with valid check digits. German IBANs use bank
    code [50010517] and a ten-digit account number; other countries get an all-digit BBAN
    of their length, so a country whose BBAN carries letters or its own national check
    digit (France, Italy, Spain, Belgium, ...) gets a well-formed IBAN whose BBAN a strict
    national validator may still refuse. Fails on a country without an IBAN length. *)
val eu_iban : ?country:string -> key:string -> unit -> Iban.t Or_error.t

(** {2 GB} *)

(** [99-00-00]: no range of the published modulus tables covers it, so it names no real
    bank. *)
val uk_sort_code : Sort_code.t

(** A synthetic weight table line for [99-00-00] to [99-00-99] (standard MOD11 weights,
    [8 7 6 5 4 3 2 1] over the account number), so the fake's account numbers can be
    checked like real ones. *)
val uk_modulus_rule : Uk_modulus.Rule.t

(** A sort code ([uk_sort_code] by default) and an eight-digit account number that passes
    [modulus] (by default a table holding only {!uk_modulus_rule}). The number is the
    first of up to 100 candidates, counting up from the hashed one, that the table accepts
    or cannot check; a sort code whose rules accept none of them (a few exception rules)
    keeps the hashed number. *)
val uk_account
  :  ?modulus:Uk_modulus.Table.t
  -> ?sort_code:Sort_code.t
  -> key:string
  -> unit
  -> Uk_account.t

(** {2 US} *)

(** [123456780]: a valid check digit, not looked up in the Federal Reserve's directory. *)
val us_routing : Aba.t

(** A checking account at [routing] (default {!us_routing}) with a ten-digit account
    number. *)
val us_account : ?routing:Aba.t -> key:string -> unit -> Us_account.t

(** {2 KG} *)

(** [Local { scheme = Account.Address.Local_scheme.kg; fields }] with [bank_code]
    ([999001], six digits like a national bank identifier) and [account_number] (sixteen
    digits starting with the bank code's first three, as domestic numbers do). *)
val kg : key:string -> Account.Address.t

(** {2 CH} *)

(** A Swiss IBAN: institution id [08999] (not looked up) and a twelve-digit account
    number. *)
val ch_iban : key:string -> Iban.t

(** The QR-IBAN for the same account: the same account number under institution id

    [30999], in the [30000] to [31999] range reserved for QR-IBANs. *)
val ch_qr_iban : key:string -> Iban.t

(** [[ Iban { iban = ch_iban; bic = None }; Local { scheme = ch_qr_iban; fields = [ "qr_iban", ... ] } ]]. *)
val ch : key:string -> Account.Address.t list

(** {2 By currency} *)

(** The details a fiat account in [currency] gets: EUR {!eu_iban}, GBP {!uk_account}, USD
    {!us_account}, CHF {!val-ch}, KGS {!val-kg}. Fails for other currencies. *)
val for_currency : Money.Currency.t -> key:string -> Account.Address.t list Or_error.t
