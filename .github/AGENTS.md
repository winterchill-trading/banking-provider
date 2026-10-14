# AGENTS.md (.github/)

`workflows/ci.yml` builds and tests this repository on Ubuntu with the `ox-setup` action.
Its `pins:` block lists the sibling repositories in dependency order; keep it in sync with
`dune-project` in the same commit as a new dependency. The `obj-magic` job calls the shared
reusable workflow from the `infra` repository.
