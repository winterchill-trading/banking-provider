open! Core

type t = string

let sexp_of_t (_ : t) = Sexp.Atom "<redacted>"
let of_string t = t
let reveal t = t

let constant_time_equal a b =
  let la = String.length a
  and lb = String.length b in
  let n = Int.max la lb in
  (* Fold every byte position of the longer string, so the time does not depend on where
     the first difference is. *)
  let diff = ref (la lxor lb) in
  for i = 0 to n - 1 do
    let ca = if i < la then Char.to_int (String.unsafe_get a i) else 0 in
    let cb = if i < lb then Char.to_int (String.unsafe_get b i) else 0 in
    diff := !diff lor (ca lxor cb)
  done;
  !diff = 0
;;

let equal = constant_time_equal
