# Repository guidance

## Upstream schema synchronization

- Treat `vendor/copilot/upstream.json`, `vendor/copilot/schemas/*.json`,
  `sync/schema-snapshot.json`, `sync/public-rpc-surface.json`, and
  `sync/extensibility-contract.json` as generated outputs owned by
  `scripts/sync.mjs`; do not edit them by hand.
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
- Release remote event-interest handles before deinitializing event queues,
  tools, callback registries, or extension runtimes because the release RPC can
  dispatch interleaved notifications and server requests.
- Treat OAuth tokens and granted environment variables as secrets in every
  representation. Wipe encoded requests, flushed writer buffers, raw responses,
  intermediate JSON, owned copies, and partial-construction cleanup paths
  before releasing their storage.
- Derive wire field names from the pinned schemas, not upstream language SDK
  public names; those layers may intentionally rename fields.
