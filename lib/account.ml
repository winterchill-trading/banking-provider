open! Core
open Payments_core

module Address = struct
  module T = struct
    type t =
      | Iban of
          { iban : Iban.Stable.V1.t
          ; bic : Bic.Stable.V1.t option
          }
      | Crypto of
          { address : Crypto_address.Stable.V2.t
          ; memo : string option
          }
      | Lightning_node of { node_id : string }
      | Uk_account of Uk_account.Stable.V1.t
      | Us_account of Us_account.Stable.V1.t
    [@@deriving bin_io, sexp, compare, equal]
  end

  module Stable = struct
    module V2 = T

    module V1 = struct
      (* The original three addresses: the bin_prot shape and digest come from here. *)
      module Repr = struct
        type t =
          | Iban of
              { iban : Iban.Stable.V1.t
              ; bic : Bic.Stable.V1.t option
              }
          | Crypto of
              { address : Crypto_address.Stable.V1.t
              ; memo : string option
              }
          | Lightning_node of { node_id : string }
        [@@deriving bin_io]
      end

      type t = T.t [@@deriving sexp, compare, equal]

      include
        Binable.Of_binable_without_uuid [@alert "-legacy"]
          (Repr)
          (struct
            type nonrec t = t

            let to_binable : t -> Repr.t = function
              | Iban { iban; bic } -> Iban { iban; bic }
              | Crypto { address; memo } -> Crypto { address; memo }
              | Lightning_node { node_id } -> Lightning_node { node_id }
              | Uk_account account ->
                raise_s
                  [%message
                    "Account.Address.Stable.V1 cannot hold UK details; write V2"
                      ~_:(Uk_account.to_string account : string)]
              | Us_account account ->
                raise_s
                  [%message
                    "Account.Address.Stable.V1 cannot hold US details; write V2"
                      ~_:(Us_account.to_string account : string)]
            ;;

            let of_binable : Repr.t -> t = function
              | Iban { iban; bic } -> Iban { iban; bic }
              | Crypto { address; memo } -> Crypto { address; memo }
              | Lightning_node { node_id } -> Lightning_node { node_id }
            ;;
          end)
    end
  end

  type t = T.t =
    | Iban of
        { iban : Iban.Stable.V1.t
        ; bic : Bic.Stable.V1.t option
        }
    | Crypto of
        { address : Crypto_address.Stable.V1.t
        ; memo : string option
        }
    | Lightning_node of { node_id : string }
    | Uk_account of Uk_account.Stable.V1.t
    | Us_account of Us_account.Stable.V1.t
  [@@deriving sexp, compare, equal]

  include (Stable.V1 : Binable.S with type t := t)
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

module Stable = struct
  module V1 = struct
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
  end

  module V2 = struct
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

let iban t =
  List.find_map t.addresses ~f:(function
    | Iban { iban; _ } -> Some iban
    | Crypto _ | Lightning_node _ | Uk_account _ | Us_account _ -> None)
;;

let crypto_address t =
  List.find_map t.addresses ~f:(function
    | Crypto { address; _ } -> Some address
    | Iban _ | Lightning_node _ | Uk_account _ | Us_account _ -> None)
;;

let us_account t =
  List.find_map t.addresses ~f:(function
    | Us_account a -> Some a
    | Iban _ | Crypto _ | Lightning_node _ | Uk_account _ -> None)
;;

let uk_account t =
  List.find_map t.addresses ~f:(function
    | Uk_account a -> Some a
    | Iban { iban; _ } -> Uk_account.of_iban iban |> Result.ok
    | Crypto _ | Lightning_node _ | Us_account _ -> None)
;;

module Balance = struct
  type t =
    { account : Account_ref.t
    ; available : Money.Amount.t
    ; held : Money.Amount.t
    ; posted : Money.Amount.t
    ; as_of : Utc_time.t
    }
  [@@deriving sexp, compare, equal]
end
