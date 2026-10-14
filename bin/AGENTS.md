# AGENTS.md (bin/)

`banking-provider` executable with two subcommands, both offline on the fake provider:
`demo` (a journey through onboarding, transfer, SCA and a card authorization) and
`conformance` (runs `Conformance` against `Fake_provider`).

- The CLI output is pinned by the cram test in `test/cli.t/run.t`. Change it on purpose.
- Build from the repository root: `dune build --root .. @banking-provider/all`.
- No environment variables are read here; keep it that way.
