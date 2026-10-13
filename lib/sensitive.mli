(** A string that must never reach a log: an OTP, a webhook secret, a hosted-session or
    PAN-display token. [sexp_of_t] prints [<redacted>], and there is no [to_string]; the
    value is read with {!reveal} at the one place that sends it on. Equality runs in
    constant time, so comparing a submitted code does not leak how much of it matched. *)

open! Core

type t [@@deriving sexp_of]

val of_string : string -> t

(** The raw value, for the request that carries it. *)
val reveal : t -> string

(** Constant time in the length of the longer argument. *)
val equal : t -> t -> bool

(** Constant-time equality of two raw strings, e.g. a computed and a received signature. *)
val constant_time_equal : string -> string -> bool
