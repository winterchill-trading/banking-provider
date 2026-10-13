open! Core

module Request = struct
  type t =
    { headers : (string * string) list
    ; body : string
    }
  [@@deriving sexp_of, compare, equal]

  let header t name =
    List.find_map t.headers ~f:(fun (k, v) ->
      Option.some_if (String.Caseless.equal k name) v)
  ;;
end

let hmac_sha256_hex ~key message =
  let mac = Cryptokit.MAC.hmac_sha256 (Sensitive.reveal key) in
  Cryptokit.hash_string mac message
  |> Cryptokit.transform_string (Cryptokit.Hexa.encode ())
;;

module Timestamped = struct
  let header_name = "x-signature"
  let signing_string ~seconds body = sprintf "%d.%s" seconds body

  let sign ~key ~at body =
    let seconds = Time_ns.to_int_ns_since_epoch at / 1_000_000_000 in
    sprintf "t=%d,v1=%s" seconds (hmac_sha256_hex ~key (signing_string ~seconds body))
  ;;

  let parse header =
    let fields =
      String.split header ~on:','
      |> List.filter_map ~f:(fun kv ->
        match String.lsplit2 kv ~on:'=' with
        | Some (k, v) -> Some (String.strip k, String.strip v)
        | None -> None)
    in
    match
      ( List.Assoc.find fields ~equal:String.equal "t"
      , List.Assoc.find fields ~equal:String.equal "v1" )
    with
    | Some t, Some v1 ->
      (match Int.of_string_opt t with
       | Some seconds -> Ok (seconds, v1)
       | None -> Or_error.error_string "webhook signature: bad timestamp")
    | _ -> Or_error.error_string "webhook signature: malformed header"
  ;;

  let verify ~key ?(tolerance = Time_ns.Span.of_min 5.) ~now (request : Request.t) =
    let open Or_error.Let_syntax in
    let%bind header =
      Request.header request header_name
      |> Or_error.of_option ~error:(Error.of_string "webhook signature: missing header")
    in
    let%bind seconds, received = parse header in
    let expected = hmac_sha256_hex ~key (signing_string ~seconds request.body) in
    let%bind () =
      if Sensitive.constant_time_equal expected (String.lowercase received)
      then Ok ()
      else Or_error.error_string "webhook signature: mismatch"
    in
    let signed_at = Time_ns.of_int_ns_since_epoch (seconds * 1_000_000_000) in
    let skew = Time_ns.Span.abs (Time_ns.diff now signed_at) in
    if Time_ns.Span.equal tolerance Time_ns.Span.zero
       || Time_ns.Span.( <= ) skew tolerance
    then Ok ()
    else
      Or_error.error_s
        [%message "webhook signature: outside the replay window" (skew : Time_ns.Span.t)]
  ;;
end
