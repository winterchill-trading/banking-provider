(** Opaque id: the provider's id for one event (webhook delivery); the inbox key, so a
    redelivered event is applied once. *)

include Payments_core.Opaque_id.S
