---
name: code-review
description: Review pull requests in this Zig Copilot SDK fork for pinned protocol parity, generated-artifact integrity, and lifecycle safety.
---

# Review this repository

Review only changed behavior and the contracts it touches. Report a finding
when the change violates a pinned wire contract, can corrupt local/remote
session state, leaks secret material, or leaves generated evidence stale.

## Pinned protocol and generated evidence

1. If a change touches SDK RPCs, events, models, providers, or extensibility,
   inspect `vendor/copilot/upstream.json`, the owning schema in
   `vendor/copilot/schemas/`, and the relevant declaration/source assertion in
   `scripts/sync.mjs`.
2. Require generated changes to come from `scripts/sync.mjs`. The generated
   outputs are:
   - `src/protocol_version.zig`
   - `src/session_event_generated.zig`
   - `sync/schema-snapshot.json`
   - `sync/public-rpc-surface.json`
   - `sync/extensibility-contract.json`
   - `sync/stable-parity-contract.json`
   - `vendor/copilot/upstream.json`
   - `vendor/copilot/schemas/*.json`
3. Check that generation and `--check` derive compatibility ledgers from the
   same canonical expected structure and run the same declaration/source
   assertions. Comparing only an upstream commit or JSON shape is insufficient.
4. For manually mirrored Zig enums, require an exact upstream value-set
   assertion in `npm test`.
5. Scope TypeScript checks to the declaration that owns the field. Account for
   inherited lifecycle fields, `Omit` exclusions, intersection
   re-declarations, startup initialization, and response handling; a name found
   elsewhere in concatenated source is not evidence.
6. Changes to `.github/workflows/sync-upstream.yml` must continue to verify the
   latest public `github/copilot-sdk` `main` even when no new CLI schema package
   is published. Verification failure opens or refreshes the
   `Upstream Copilot SDK parity drift detected` issue; success closes it.

## Session and transport lifecycle

For changes in `src/client.zig`, `src/runtime.zig`, `src/event_log.zig`, or
`src/extensibility.zig`, verify these invariants:

- A successful `session.create` or `session.resume` has already mutated CLI
  state. Post-response failure must detach a newly attached session. Resident
  resume must retain the previous runtime and session-ID allocation until the
  replacement is fully prepared.
- Lifecycle callbacks resolve an exact pending runtime first, then committed
  runtimes, and use an ID-less create runtime only as the final fallback.
- Release remote event-interest handles before detach or local queue/tool/hook
  teardown. A failed pre-detach release retains local state; a later detach
  failure best-effort restores released interest.
- On clean child EOF, mark the logical transport closed before waiting. Do not
  clear `Child.id` after a failed wait because Windows process and pipe handles
  may still require shutdown cleanup.

## Wire validation and secrets

- Validate handler-produced values before responding. Invalid OAuth token
  results must be securely deinitialized and the pending request cancelled.
- Every inbound server request receives a correlated response: malformed
  fields map to `-32602`, invalid handler output to `-32603`.
- Wire field names come from pinned schemas and wire normalization. Required
  `unknown` fields reject omission but preserve explicit `null`; JSON
  Schema-valued fields accept boolean and object schemas.
- Optional arrays preserve omitted versus explicitly empty forms when their
  semantics differ. MCP HTTP headers reject duplicate names
  case-insensitively.
- OAuth tokens and environment grants are wiped in encoded requests, raw
  responses, intermediate JSON, owned copies, partial construction cleanup,
  and streaming transport backing buffers.

## Evidence

For affected changes, expect:

```sh
zig fmt --check build.zig src examples scripts/parity_census_runner.zig
zig build test
npm test
```

Also require `zig build --build-file examples/<name>/build.zig` when an example
or its exercised API changes. A finding is actionable when the diff lacks the
test, generated update, or cleanup path needed to prove one of the invariants
above.
