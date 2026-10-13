(lang dune 3.17)

(name banking-provider)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/banking-provider))

(package
 (name banking-provider)
 (synopsis
  "Banking-as-a-service provider boundary: module type, normalized events, deterministic fake")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  core_unix
  async
  async_kernel
  ppx_jane
  zarith
  cryptokit
  money
  ledger
  kyc-core
  payments-core
  card-core))
