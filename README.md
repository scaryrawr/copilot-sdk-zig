# Copilot SDK for Zig

This repository contains an unofficial Zig SDK for GitHub Copilot CLI. The
community maintains it. GitHub does not support or endorse this SDK.

The SDK starts Copilot CLI as a child process and exchanges JSON-RPC messages
over standard input and standard output. Its API is blocking and
single-threaded.

## Requirements

- Zig 0.16.0
- GitHub Copilot CLI in `PATH`, or its path in `ClientOptions.cli_path`

## Install from GitHub

Add the package to `build.zig.zon`:

```sh
zig fetch --save=copilot_sdk git+https://github.com/scaryrawr/copilot-sdk-zig
```

Pin a release tag or commit in production projects. Add the module to your
compile step in `build.zig`:

```zig
const copilot_dependency = b.dependency("copilot_sdk", .{
    .target = target,
    .optimize = optimize,
});
executable.root_module.addImport(
    "copilot_sdk",
    copilot_dependency.module("copilot_sdk"),
);
```

The package also exposes a `copilot_schema` module for deriving custom-tool
JSON Schemas from Zig structs at comptime:

```zig
const schema = @import("copilot_schema");

const WeatherArguments = struct {
    city: []const u8,
    unit: ?enum { celsius, fahrenheit },
};

const weather_tool = schema.defineTool(WeatherArguments, .{
    .name = "get_weather",
    .description = "Get weather for a city.",
    .handler = struct {
        fn handle(
            allocator: std.mem.Allocator,
            arguments: WeatherArguments,
        ) ![]u8 {
            return std.fmt.allocPrint(
                allocator,
                "Weather for {s}",
                .{arguments.city},
            );
        }
    }.handle,
});
```

## Send a prompt

Pass a `std.Io` implementation to `Client.init`. The client starts
`copilot --headless --stdio --no-auto-update` and completes the `connect`
handshake before it returns. Set `ClientOptions.client_info` to identify the
integrating application and SDK surface in runtime telemetry.

```zig
const std = @import("std");
const copilot = @import("copilot_sdk");

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    var client = try copilot.Client.init(allocator, io, .{});
    defer client.deinit();

    const session = try client.createSession(.{ .streaming = true });
    defer session.disconnect() catch {};

    const message_id = try session.send(.{ .prompt = "Explain this repository." });
    defer allocator.free(message_id);

    while (true) {
        var event = try session.nextEvent();
        defer event.deinit(allocator);

        switch (event) {
            .assistant_message => |message| {
                _ = message;
            },
            .assistant_message_delta => |delta| {
                _ = delta;
            },
            .session_idle => break,
            .session_error => return error.CopilotSessionError,
            .commands_changed => {},
            .unknown => {},
            else => {},
        }
    }
}
```

`Session` borrows its `Client`. Keep the client alive while a session handle is
in use. `SessionEvent` values and the message ID from `send` own memory from the
client allocator. `Session.disconnect` releases the client-side session
resources while preserving the session state so it can be resumed later.

## Discover slash commands

List runtime, skill, and client-contributed slash commands after creating a
session. A `commands_changed` event indicates that extensions or another
participant changed the available command set and the caller should list again.

```zig
var commands = try session.listCommands(.{});
defer commands.deinit();

for (commands.commands) |command| {
    std.debug.print("/{s}\t{s}\n", .{
        command.name,
        command.description,
    });
}
```

## Use a custom provider

Set `SessionConfig.provider` for a static custom provider:

```zig
const session = try client.createSession(.{
    .provider = .{
        .base_url = "https://api.openai.com/v1",
        .protocol = .{ .openai = .{ .responses = .http } },
        .authentication = .{ .api_key = "provider-api-key" },
        .headers = &.{
            .{ .name = "X-Tenant", .value = "acme" },
        },
        .model_id = "gpt-4.1",
        .wire_model = "deployment-name",
        .max_prompt_tokens = 100_000,
        .max_output_tokens = 16_384,
    },
});
```

`ProviderConfig.Protocol` supports OpenAI Chat Completions, OpenAI Responses
over HTTP or WebSocket, Azure with an optional API version, and Anthropic.
`ProviderConfig.Authentication` supports no credentials, one API key, or one
static bearer token. Credentials are optional so local providers work without
authentication.

The SDK rejects empty header names and duplicate names without regard to ASCII
case. It does not parse `base_url`.

`bearerTokenProvider`, `hasBearerTokenProvider`, named providers and models,
`providerName`, `modelCapabilities`, `maxContextWindowTokens`, alternate SDK
transports, new events, and callback dispatch are deferred.

## Examples

Runnable projects are listed in [`examples`](examples). They cover streaming,
custom tools, permission decisions, prompt customization, and joining a
foreground CLI session from an extension.

```sh
cd examples/basic
zig build
zig build run -- --help
zig build run
```

The last command requires the Copilot CLI in `PATH`. Use
`zig build run -- --cli-path /path/to/copilot` when it is installed elsewhere.
CI builds every example and runs credential-free help paths, while the SDK unit
tests verify protocol behavior without requiring Copilot credentials.

## Supported scope

The SDK supports only the stdio transport. It implements these wire methods:

- `connect`
- `session.create`
- `session.resume`
- `session.send`
- `session.model.switchAutoTier`
- `session.detach`
- `session.event`
- `session.permissions.handlePendingPermissionRequest`
- `session.tools.handlePendingToolCall`

It recognizes these session events:

- `assistant.message`
- `assistant.message_delta`
- `session.idle`
- `session.error`
- `permission.requested`
- `external_tool.requested`

Other session events use the `unknown` variant. The SDK does not support an
external CLI server URL or the broader APIs in the upstream schema.

The client stores at most 1,024 queued session events. An RPC call or event read
returns `error.EventQueueFull` when callers leave other sessions undrained.

## Develop

Run the checks from the repository root:

```sh
zig fmt --check build.zig src examples
zig build test
zig build
for example in basic custom-tools external-tools permissions prompt-customization send-and-wait join-session; do
  zig build --build-file "examples/$example/build.zig"
done
npm ci
npm test
```

Run `npm run sync` to update the upstream metadata, the two schema snapshots,
and `src/protocol_version.zig`.

## Upstream sync policy

`vendor/copilot/upstream.json` records the `github/copilot-sdk` main commit, the
SDK protocol version, the exact Copilot CLI version from the upstream Node
package manifest, the verified CLI release asset, and SHA-256 digests for the
asset and both schema snapshots.

The sync script downloads the Linux x64 package from the corresponding
`github/copilot-cli` release and verifies it against the release's
`SHA256SUMS.txt`. It copies only `api.schema.json` and
`session-events.schema.json`. It then generates the Zig protocol version
constant and `sync/schema-snapshot.json`.

The snapshot contains every RPC method, every session event discriminator, and
the vendored `ProviderConfig` contract. `npm test` checks the snapshot and the
supported or deferred classification for every provider property in
`sync/compatibility.json`.

The published API schema declares the supported handshake, message, model,
permission, and tool-response methods. Copilot SDKs own the
`session.create`, `session.resume`, `session.detach`, and `session.event`
lifecycle messages, so the compatibility check verifies those names in
`src/client.zig`.

The scheduled workflow checks upstream once a week. When inputs change, it
updates one `sync/upstream` branch and opens or refreshes one pull request. The
workflow waits for the exact CLI package version to reach the registry and
never force-pushes.

## License

The SDK is available under the MIT License. See `NOTICE` for the required
notice for source adapted from `github/copilot-sdk`.
