open! Core
open Payments_core

module Address = struct
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

let iban t =
  List.find_map t.addresses ~f:(function
    | Iban { iban; _ } -> Some iban
    | Crypto _ | Lightning_node _ -> None)
;;

let crypto_address t =
  List.find_map t.addresses ~f:(function
    | Crypto { address; _ } -> Some address
    | Iban _ | Lightning_node _ -> None)
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
