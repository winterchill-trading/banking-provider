open! Core
open Payments_core

module Line = struct
  type t =
    { at : Utc_time.t
    ; amount : Money.Amount.t
    ; code : string
    ; reference : string
    ; balance : Money.Amount.t
    }
  [@@deriving sexp, compare, equal]
end

type t =
  { account : Account_ref.t
  ; currency : Money.Currency.t
  ; from : Utc_time.t
  ; until : Utc_time.t
  ; opening : Money.Amount.t
  ; lines : Line.t list
  ; closing : Money.Amount.t
  }
[@@deriving sexp, compare, equal]

let check t =
  let open Or_error.Let_syntax in
  let%bind last =
    List.fold_result t.lines ~init:t.opening ~f:(fun running (line : Line.t) ->
      let%bind next = Money.Amount.add running line.amount in
      if Money.Amount.equal next line.balance
      then Ok next
      else
        Or_error.error_s
          [%message
            "statement line balance does not follow"
              ~reference:line.reference
              (next : Money.Amount.t)
              ~balance:(line.balance : Money.Amount.t)])
  in
  if Money.Amount.equal last t.closing
  then Ok ()
  else
    Or_error.error_s
      [%message
        "statement closing balance does not follow"
          (last : Money.Amount.t)
          ~closing:(t.closing : Money.Amount.t)]
;;
