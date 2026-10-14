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
      | Local of
          { scheme : string
          ; fields : (string * string) list
          }
    [@@deriving bin_io, sexp, compare, equal]
  end

  let local_raise scheme ~version =
    raise_s
      [%message
        (sprintf "Account.Address.Stable.%s cannot hold local details; write V3" version)
          ~_:(scheme : string)]
  ;;

  module Stable = struct
    module V3 = T

    module V2 = struct
      (* The five addresses before [Local]: the bin_prot shape and digest come from here. *)
      module Repr = struct
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
              | Uk_account a -> Uk_account a
              | Us_account a -> Us_account a
              | Local { scheme; fields = _ } -> local_raise scheme ~version:"V2"
            ;;

            let of_binable : Repr.t -> t = function
              | Iban { iban; bic } -> Iban { iban; bic }
              | Crypto { address; memo } -> Crypto { address; memo }
              | Lightning_node { node_id } -> Lightning_node { node_id }
              | Uk_account a -> Uk_account a
              | Us_account a -> Us_account a
            ;;
          end)
    end

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
              | Local { scheme; fields = _ } -> local_raise scheme ~version:"V1"
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
    | Local of
        { scheme : string
        ; fields : (string * string) list
        }
  [@@deriving sexp, compare, equal]

  include (Stable.V1 : Binable.S with type t := t)

  module Local_scheme = struct
    let kg = "kg"
    let ch_qr_iban = "ch_qr_iban"
  end

  (* Field names are lower snake case ([bank_code]); a few are acronyms people expect in
     capitals. *)
  let label_of_field = function
    | "iban" -> "IBAN"
    | "qr_iban" -> "QR-IBAN"
    | "bic" -> "BIC"
    | name -> String.capitalize (String.tr name ~target:'_' ~replacement:' ')
  ;;

  let to_display_lines = function
    | Iban { iban; bic } ->
      ("IBAN " ^ Iban.to_string_grouped iban)
      :: Option.to_list (Option.map bic ~f:(fun bic -> "BIC " ^ Bic.to_string bic))
    | Crypto { address; memo } ->
      sprintf
        "%s address %s"
        (String.tr
           (Sexp.to_string (Network.sexp_of_t (Crypto_address.network address)))
           ~target:'_'
           ~replacement:' ')
        (Crypto_address.address address)
      :: Option.to_list (Option.map memo ~f:(fun memo -> "Memo " ^ memo))
    | Lightning_node { node_id } -> [ "Lightning node " ^ node_id ]
    | Uk_account a ->
      [ "Sort code " ^ Sort_code.to_string_hum a.sort_code
      ; "Account number " ^ a.account_number
      ]
      @ Option.to_list (Option.map a.roll_number ~f:(fun r -> "Roll number " ^ r))
    | Us_account a ->
      [ "Routing number " ^ Aba.to_string a.routing
      ; "Account number " ^ a.account_number
      ; (match a.account_type with
         | Checking -> "Checking account"
         | Savings -> "Savings account")
      ]
    | Local { scheme = _; fields } ->
      List.map fields ~f:(fun (name, value) ->
        let value =
          (* IBAN-shaped fields read in groups of four, as printed IBANs do. *)
          match name with
          | "iban" | "qr_iban" ->
            (match Iban.of_string value with
             | Ok iban -> Iban.to_string_grouped iban
             | Error _ -> value)
          | _ -> value
        in
        label_of_field name ^ " " ^ value)
  ;;
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

  module V3 = struct
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

let iban t =
  List.find_map t.addresses ~f:(function
    | Iban { iban; _ } -> Some iban
    | Crypto _ | Lightning_node _ | Uk_account _ | Us_account _ | Local _ -> None)
;;

let crypto_address t =
  List.find_map t.addresses ~f:(function
    | Crypto { address; _ } -> Some address
    | Iban _ | Lightning_node _ | Uk_account _ | Us_account _ | Local _ -> None)
;;

let us_account t =
  List.find_map t.addresses ~f:(function
    | Us_account a -> Some a
    | Iban _ | Crypto _ | Lightning_node _ | Uk_account _ | Local _ -> None)
;;

let uk_account t =
  List.find_map t.addresses ~f:(function
    | Uk_account a -> Some a
    | Iban { iban; _ } -> Uk_account.of_iban iban |> Result.ok
    | Crypto _ | Lightning_node _ | Us_account _ | Local _ -> None)
;;

let local t ~scheme =
  List.find_map t.addresses ~f:(function
    | Local { scheme = s; fields } when String.equal s scheme -> Some fields
    | Iban _ | Crypto _ | Lightning_node _ | Uk_account _ | Us_account _ | Local _ -> None)
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
