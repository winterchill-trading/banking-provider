(** Webhook deliveries and their signatures.

    A delivery is checked on its raw bytes before anything parses it: recompute the HMAC,
    compare in constant time, then decode. Each provider has its own header and signing
    string, so {!Provider.S.ingest_webhook} does the provider-specific part; this module
    holds the shared pieces and the timestamped scheme the fake provider uses
    ([t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<body>">], the common public-API
    shape), whose timestamp bounds replays to a tolerance window. *)

open! Core

module Request : sig
  type t =
    { headers : (string * string) list (** names compared case-insensitively *)
    ; body : string (** the raw bytes, exactly as received *)
    }
  [@@deriving sexp_of, compare, equal]

  val header : t -> string -> string option
end

(** Lower-case hex HMAC-SHA256 of [message] under [key]. *)
val hmac_sha256_hex : key:Sensitive.t -> string -> string

module Timestamped : sig
  val header_name : string

  (** The header value for [body] signed at [at]. *)
  val sign : key:Sensitive.t -> at:Time_ns.t -> string -> string

  (** Checks the header of [request] against its body. Fails on a missing or malformed
      header, a wrong signature, or a timestamp more than [tolerance] (default five
      minutes) away from [now]; a zero tolerance skips the time check. The error never
      contains the expected signature. *)
  val verify
    :  key:Sensitive.t
    -> ?tolerance:Time_ns.Span.t
    -> now:Time_ns.t
    -> Request.t
    -> unit Or_error.t
end
