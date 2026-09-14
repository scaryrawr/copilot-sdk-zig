# Repository guidance

## Project stance

- This is an unofficial, vibe-maintained Zig fork of `github/copilot-sdk`.
  Favor a clear Zig API and correct behavior against the pinned wire contracts.
- Breaking public API changes are allowed. Do not add compatibility wrappers,
  deprecated aliases, or migration layers unless the pinned protocol requires
  them or the task explicitly asks for them.
- Preserve exact commit/version pins in upstream metadata and GitHub Actions.
  Do not loosen an existing pin for convenience.

## Architecture

- `src/root.zig` is the public module surface. `src/client.zig` owns the
  blocking, single-threaded client, transport implementations, child CLI
  lifecycle, and per-session extension runtime; `src/session.zig` owns public
  session types; `src/runtime.zig` owns public connection, callback, and
  filesystem-provider configuration types; `src/extensibility.zig` owns hooks,
  MCP, skills, canvases, and environment grants.
- The client starts Copilot CLI and exchanges JSON-RPC over stdio by default.
  Preserve explicit ownership and `deinit` behavior for allocated results.
- `scripts/sync.mjs` owns `vendor/copilot/upstream.json`,
  `vendor/copilot/schemas/*.json`, `src/protocol_version.zig`,
  `src/session_event_generated.zig`, and the generated contract files under
  `sync/`. Never edit those outputs manually.

## Toolchain and validation

- Use Zig 0.16.0 and Node.js 24. Install Node dependencies with `npm ci`.
- Run the repository checks from the root:

  ```sh
  zig fmt --check build.zig src examples scripts/parity_census_runner.zig
  zig build test
  zig build
  npm test
  ```

- Build an affected example with
  `zig build --build-file examples/<name>/build.zig`. Examples other than
  `join-session` also support `run -- --help` without authentication.
- `npm test` runs the JavaScript contract tests and `scripts/sync.mjs --check`;
  it is required after SDK, schema, generator, or synchronization changes.

## Upstream synchronization

- `npm run sync` intentionally advances both the public SDK commit and Copilot
  CLI package. Do not run it merely to refresh generated files on a branch.
- To regenerate at the existing pin, read `upstreamCommit` from
  `vendor/copilot/upstream.json`, then run:

  ```sh
  npm run sync -- --commit <upstreamCommit>
  npm test
  ```

## Implementation constraints

- Treat OAuth tokens and granted environment variables as secrets: wipe every
  owned or encoded representation, including failure cleanup and transport
  buffers.
- Inbound server requests must always receive a correlated JSON-RPC response.
  Use `-32602` for malformed input and `-32603` for invalid handler output.
- Derive wire names and required/null semantics from the pinned schemas and
  upstream wire normalization, not from public TypeScript names.
- Treat optional inbound session-event fields as nullable at the decode
  boundary. The CLI may emit explicit JSON `null` where the pinned schema only
  documents omission; all generated and event-specific parser branches must
  preserve required-field checks while accepting both optional shapes.
- Preserve omitted versus explicitly empty optional arrays when the protocol
  gives them different meanings. Reject duplicate HTTP header names
  case-insensitively.
- See `.github/skills/code-review/SKILL.md` for the lifecycle and parity checks
  required when reviewing changes.
