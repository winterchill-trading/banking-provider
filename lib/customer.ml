open! Core
open Payments_core

type t =
  { id : Customer_ref.t
  ; customer_id : Kyc_core.Customer_id.t
  ; created_at : Utc_time.t
  }
[@@deriving sexp, compare, equal]

module Kyc_status = struct
  open Kyc_core

  type t =
    { customer : Customer_ref.t
    ; status : Status.t
    ; tier : Tier.t
    ; steps : (Verification.Step.t * Verification.State.t) list
    }
  [@@deriving sexp, compare, equal]

  let initial customer =
    { customer
    ; status = Created
    ; tier = T0
    ; steps = List.map Verification.Step.all ~f:(fun step -> step, Verification.State.Pending)
    }
  ;;

  let with_step t step state =
    let steps =
      List.map t.steps ~f:(fun (s, st) ->
        if Verification.Step.equal s step then s, state else s, st)
    in
    let verified =
      List.filter_map steps ~f:(fun (s, st) ->
        Option.some_if (Verification.State.is_verified st) s)
      |> Verification.Step.Set.of_list
    in
    { t with steps; tier = Tier.Rules.tier_of Tier.Rules.default ~verified }
  ;;
end

module Verification_session = struct
  type t =
    | Code_sent of
        { step : Kyc_core.Verification.Step.t
        ; expires_at : Utc_time.t
        }
    | Hosted of
        { step : Kyc_core.Verification.Step.t
        ; token : Sensitive.t
        ; expires_at : Utc_time.t
        }
  [@@deriving sexp_of]

  let step = function
    | Code_sent { step; _ } | Hosted { step; _ } -> step
  ;;
end
