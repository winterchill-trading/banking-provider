# AGENTS.md

## Purpose

This library is the boundary between an application and a banking-as-a-service provider:
the `Provider.S` contract, the normalized `Event.t` every provider reports in, and a
deterministic in-memory `Fake_provider` that books into a ledger. A `Conformance` functor
runs the same scenarios against any implementation, the fake included.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | Library `banking_provider`: `Provider`, `Sandbox`, `Event`, `Transfer_update`, `Card_update`, `Webhook`, `Inbox`, `Sensitive`, `Fake_provider`, `Conformance` (see `lib/AGENTS.md`) |
| `bin/` | `banking-provider` executable: `demo` and `conformance` (see `bin/AGENTS.md`) |
| `test/` | Expect, Quickcheck and cram tests (see `test/AGENTS.md`) |
| `docs/` | `contract.md`: what an adapter must normalize and why |
| `.github/` | CI workflow (see `.github/AGENTS.md`) |
| `dune-project`, `banking-provider.opam` | Package metadata; the `.opam` file is generated from `dune-project` |

## Build, test, docs

Run from this directory. The workspace root `..` holds the sibling checkouts and the shared
`dune-workspace`.

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @banking-provider/all
opam exec --switch 5.2.0+ox -- dune build --root .. @banking-provider/runtest
DUNE_BUILD_DIR=_build-banking-provider opam exec --switch 5.2.0+ox -- dune build --root .. @banking-provider/all
```

The last line is for parallel work: a private build directory avoids the lock shared with
other repositories in the workspace.

Standalone (outside the workspace), pin the siblings from GitHub as the CI workflow does,
then build:

```sh
opam pin add -n -y fixed-decimal https://github.com/winterchill-trading/fixed-decimal.git
# repeat for money, ledger, kyc-core, payments-core, card-core (see .github/workflows/ci.yml)
opam install . --deps-only --with-test
dune build && dune test
```

Demo and conformance run offline: `dune exec banking-provider -- demo` and
`dune exec banking-provider -- conformance`.

## Conventions

- Formatting: `dune build --root .. @banking-provider/fmt --auto-promote`, run after the tests
  pass. Never `dune fmt` at the workspace root; it reformats every sibling repository.
- Every module has an `.mli`. Use `open! Core`, labelled arguments and `ppx_jane`.
- Tests are `ppx_expect` inline tests with `-source-tree-root .`, plus `Base_quickcheck`
  properties for invariants (balances, idempotent updates).
- Types that cross a boundary are `Stable.V1` with a pinned `[%bin_digest]`. A change to a
  pinned digest is a version decision: the expect test that pins it fails first.
- The library names no provider, HTTP client or credential. Keep it that way.
- Add a short comment at any non-obvious choice, such as the constant-time signature compare.
- Document every public value in its `.mli` with odoc comments.

## Dependencies and dependents

- Depends on: `money`, `ledger`, `kyc-core`, `payments-core`, `card-core` (and
  `fixed-decimal` through them). No database and no HTTP client.
- Used by: adapters for real providers, which implement `Provider.S` and
  `Sandbox.S`; applications that run against `Fake_provider` in tests.
- CI pin order: `fixed-decimal`, `money`, `ledger`, `kyc-core`, `payments-core`, `card-core`.
  A new sibling dependency needs its pin in the CI workflow in the same commit.

## CI

`.github/workflows/ci.yml` runs the `ox-setup` action with the pins above (its opam switch
is cached between runs), then `dune build` and `dune test`. The `obj-magic` job calls the
shared reusable workflow, which fails on `Obj.magic`, `Obj.repr` or `Obj.obj` in the sources.
To check a run: `gh run list --limit 1`, then at most one `gh run watch <id> --exit-status`.
Do not poll in a loop.

## Pitfalls

- Do not `open` a sibling library that is still changing (`card-core` broke this build
  when it added modules that shadowed local names). Alias the modules you use.
- A module that defines its own `Stable` cannot `include Int`; include
  `Identifiable.S` with the type equality instead.
- `String.Map.Stable` does not exist; write `string String.Stable.V1.Map.t`.
- `Time_ns` sexps print in the local time zone. Use `Time_ns.Stable.Alternate_sexp.V1` in
  expect output so macOS and CI agree.
- Bookings take their time from `Ledger.Journal.now`, not from a synthetic clock that stands
  still; a frozen clock makes idempotency keys collide.
- The fake's webhook signatures expire after five minutes of its clock. Redeliver inside the
  window to test de-duplication, or the request fails at the signature check first.
- `dune promote` fills cram output. Read the diff before promoting; it overwrites edits made
  after the failing run.

## Where to read more

- `README.md` (usage, modules, known gaps), `docs/contract.md` (adapter obligations).
- `../specs/repos/banking-provider.md` for status and the design decisions.
- Skills in `../oxcaml-claude-skills/skills/`: `banking-standards`, `janestreet-ocaml-style`.
- `../oxcaml-claude-skills/AGENTS.md`: the workspace-wide guide.
- `../oxcaml-claude-skills/GOTCHAS.md`: the dated log these pitfalls come from.

## Never do

- Run `opam install`, `opam upgrade` or `opam pin` on the shared `5.2.0+ox` switch without a
  dry run first: `opam install --switch 5.2.0+ox --dry-run <pkg>`. Abort if the plan touches
  `ocaml-variants`, `core`, `base`, `async` or `ppx_jane`.
- Publish, tag or release a version from this repository without the maintainers asking.
- Commit credentials or print secrets. Configuration comes from the environment.
- Poll CI in a loop.
