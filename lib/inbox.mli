(** An in-memory inbox: applies each provider event id once.

    The durable inbox of a service lives in its own store (a table keyed by provider event
    id, written in the same transaction as the effect); this one serves tests, the fake
    provider's consumers and offline mode, with the same rule: a redelivered id is a
    duplicate, and the same id with different content is an error, since it means the
    provider (or an attacker) reused an id. *)

open! Core

type t

val create : unit -> t

module Outcome : sig
  type t =
    | New
    | Duplicate
  [@@deriving sexp, compare, equal]
end

val accept : t -> Event.t -> Outcome.t Or_error.t
val mem : t -> Event_id.t -> bool
val length : t -> int
