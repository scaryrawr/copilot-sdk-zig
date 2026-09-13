# Repository guidance

## Upstream schema synchronization

- Treat `vendor/copilot/upstream.json`, `vendor/copilot/schemas/*.json`,
  `sync/schema-snapshot.json`, `sync/public-rpc-surface.json`, and
  `sync/extensibility-contract.json` as generated outputs owned by
  `scripts/sync.mjs`; do not edit them by hand.
- Generate and verify compatibility ledgers from the same canonical expected
  structure; checking only their upstream commit allows manual drift to pass.
- When Zig manually mirrors an enum from the pinned schemas, verify the exact
  upstream value set in `npm test`; pinning the schema does not update the Zig
  type when upstream adds a variant.
- Scope upstream API checks to the TypeScript declaration that owns each field,
  including inherited lifecycle fields, `Omit` exclusions, intersection
  re-declarations, startup initialization, and response handling; searching
  concatenated source only proves that a name exists somewhere.
- `npm run sync` advances to the latest upstream `github/copilot-sdk` commit and
  Copilot CLI package. Do not use it when refreshing generated files for an
  existing branch unless advancing the pin is intentional.
- To preserve the repository's current pin, read `upstreamCommit` from
  `vendor/copilot/upstream.json` and run:

  ```sh
  npm run sync -- --commit <upstreamCommit>
  npm test
  ```

## Validation

Run `zig fmt --check build.zig src examples`, `zig build test`, and `npm test`
after SDK or synchronization changes. Build affected examples with
`zig build --build-file examples/<name>/build.zig`.

## Extensibility lifecycle safety

- A successful `session.create` or `session.resume` mutates CLI state before
  local response processing finishes. Detach newly attached sessions on
  post-response failure; for resident resume, keep the previous local runtime
  and session-ID allocation until the replacement is fully prepared.
- During lifecycle RPCs, resolve an exact pending session runtime first, then
  committed runtimes, and use an ID-less create runtime only as a final fallback
  so unrelated interleaved callbacks cannot mutate the new session.
- Release remote event-interest handles before deinitializing event queues,
  tools, callback registries, or extension runtimes because the release RPC can
  dispatch interleaved notifications and server requests.
- Treat OAuth tokens and granted environment variables as secrets in every
  representation. Wipe encoded requests, raw responses, intermediate JSON,
  owned copies, partial-construction cleanup paths, and both streaming transport
  backing buffers before releasing their storage.
- Validate handler-produced values against the wire schema before responding;
  invalid OAuth token results must securely deinitialize and cancel the pending
  request rather than sending a response the CLI will reject.
- Inbound server requests must always receive a correlated JSON-RPC response;
  map malformed fields to `-32602` and invalid handler output to `-32603`
  instead of propagating errors out of the dispatch loop.
- Derive wire field names from the pinned schemas, not upstream language SDK
  public names; those layers may intentionally rename fields. When a callback
  payload is schema-opaque, inspect the pinned SDK's wire normalization too
  (for example, `stop_hook_active` becomes Node's `stopHookActive`). Required
  `unknown` fields must reject omission while preserving explicit JSON `null`.
  JSON Schema-valued fields accept boolean schemas as well as object schemas.
- Preserve omitted versus explicitly empty optional arrays when the runtime
  assigns them different semantics; model these as optional slices and cover
  both JSON shapes in request-lowering tests.
- Reject duplicate MCP HTTP header names case-insensitively; JSON object key
  equality does not model HTTP header semantics.
