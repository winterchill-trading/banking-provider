# AGENTS.md (lib/)

Library `banking_provider`: the provider contract and the fake that implements it.

- `Provider.S` and `Sandbox.S` are module types. Adapters implement them; the fake and the
  conformance suite are written against them only.
- `Event` is the normalized event union (`Stable.V1`, digest pinned). Every provider event
  carries its provider event id; `Inbox` de-duplicates by that id in memory only.
- `Fake_provider` takes its time from `Ledger.Journal.now` and uses counters for ids, so
  its output is deterministic. Keep it free of randomness and of personal data.
- `Webhook` compares signatures in constant time over the raw bytes. Keep that comparison
  as it is.
- Each `.ml` has an `.mli`; add the module to both when you add it.
- Build: `dune build --root .. @banking-provider/all` from the repository root.
