# AGENTS.md (test/)

Tests for `banking_provider` and its CLI.

- Expect tests (`ppx_expect`) cover the journeys, SCA, redelivery and the pinned event digest.
- `test_properties.ml` holds Quickcheck invariants: an update applied twice is `Stale` the
  second time, and random operations keep the trial balance at zero.
- `cli.t/run.t` is a cram test of the binary. Promote it with `dune promote` only after
  reading the diff.
- Run: `dune build --root .. @banking-provider/runtest` from the repository root.
- Use a synthetic clock and pin times; a wall-clock dependency makes outputs flaky.
