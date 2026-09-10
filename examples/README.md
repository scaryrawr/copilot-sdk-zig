# Examples

Each directory is a standalone Zig package that depends on the SDK through a
local path.

| Example | Demonstrates |
| --- | --- |
| [`basic`](basic) | Sending a prompt, streaming response deltas, and automatically approving ordinary permissions |
| [`custom-tools`](custom-tools) | Declaring a JSON Schema tool and returning its result |
| [`external-tools`](external-tools) | Manually resolving a declaration-only tool request |
| [`permissions`](permissions) | Inspecting permission requests and applying a selective manual policy |
| [`prompt-customization`](prompt-customization) | Appending instructions to the system message |
| [`send-and-wait`](send-and-wait) | Waiting for one complete non-streaming response |
| [`join-session`](join-session) | Joining a foreground CLI session from an extension |

Build or run a normal example from its directory:

```sh
zig build
zig build run -- --help
zig build run
```

The final command requires Copilot CLI authentication.

## Join-session extension

Build the Zig executable first:

```sh
cd examples/join-session
zig build
```

Then copy `extension.mjs` into a Copilot CLI extension directory, for example
`.github/extensions/zig-join-session/extension.mjs`. The wrapper launches
`examples/join-session/zig-out/bin/join-session` from the foreground
repository. Set `COPILOT_SDK_ZIG_JOIN_SESSION_BIN` when the executable lives
elsewhere.

The extension registers `zig_extension_status`. Ask Copilot to call that tool
to verify that the Zig process joined the foreground session.
