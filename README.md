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
            .unknown => {},
            else => {},
        }
    }
}
```

Attach files or other typed context to a message:

```zig
const attachments = [_]copilot.Attachment{
    .{ .file = .{
        .path = "/workspace/src/main.zig",
        .display_name = "main.zig",
        .line_range = .{ .start = 12, .end = 28 },
    } },
};

const message_id = try session.send(.{
    .prompt = "Explain this file.",
    .attachments = &attachments,
});
defer allocator.free(message_id);
```

`MessageOptions` borrows the prompt, the attachment slice, and all attachment
data until `send` or `sendAndWait` returns. These inputs require no `deinit`.

`Session` borrows its `Client`. Keep the client alive while a session handle is
in use. `SessionEvent` values and the message ID from `send` own memory from the
client allocator. `Session.disconnect` releases the client-side session
resources while preserving the session state so it can be resumed later.

## Configure session runtime options and SessionFS

`CreateSessionConfig`, `ResumeSessionConfig`, and `JoinSessionConfig` expose the
same session runtime fields. Set them directly on the lifecycle config.
`SessionConfig` remains an alias for `CreateSessionConfig`.

```zig
const session = try client.createSession(.{
    .client_name = "acme-editor",
    .reasoning_effort = .high,
    .reasoning_summary = .concise,
    .enable_experimental_mode = false,
    .context_tier = .long_context,
    .large_output = .{
        .enabled = true,
        .max_size_bytes = 64 * 1024,
        .output_directory = "/tmp/copilot-output",
    },
    .config_directory = "/var/lib/acme/copilot",
    .capi = .{
        .auto_tier = .balance,
        .enable_websocket_responses = false,
    },
    .additional_directories = &.{"/work/shared"},
    .infinite_sessions = .{
        .enabled = true,
        .background_compaction_threshold = 0.80,
        .buffer_exhaustion_threshold = 0.95,
    },
    .memory = .{ .enabled = false },
    .skip_embedding_retrieval = true,
    .embedding_cache_storage = .in_memory,
    .organization_custom_instructions = "Use the release checklist.",
    .enable_file_hooks = false,
    .enable_host_git_operations = true,
    .enable_session_store = false,
});
```

The public field names and types are:

| Field | Type | Meaning |
| --- | --- | --- |
| `client_name` | `?[]const u8` | Identifies the integrating application. |
| `reasoning_effort` | `?ReasoningEffort` | Selects `low`, `medium`, `high`, `xhigh`, or `max`. |
| `reasoning_summary` | `?ReasoningSummary` | Selects the reasoning summary mode. |
| `enable_experimental_mode` | `?bool` | Enables or disables experimental runtime behavior. |
| `context_tier` | `?ContextTier` | Selects `default` or `long_context`. |
| `large_output` | `?LargeOutputConfig` | Sets `enabled`, `max_size_bytes`, and `output_directory`. |
| `config_directory` | `?[]const u8` | Overrides the runtime configuration directory. |
| `capi` | `?CapiSessionOptions` | Sets `auto_tier` and `enable_websocket_responses`. |
| `additional_directories` | `?[]const []const u8` | Adds directories that the session may access. |
| `infinite_sessions` | `?InfiniteSessionConfig` | Sets `enabled`, `background_compaction_threshold`, and `buffer_exhaustion_threshold`. |
| `memory` | `?MemoryConfiguration` | Sets the required nested `enabled` value. |
| `skip_embedding_retrieval` | `?bool` | Disables embedding retrieval when true. |
| `embedding_cache_storage` | `?EmbeddingCacheStorage` | Selects `persistent` or `in_memory`. |
| `organization_custom_instructions` | `?[]const u8` | Adds organization instructions to the session. |
| `enable_file_hooks` | `?bool` | Enables or disables file-based hooks. |
| `enable_host_git_operations` | `?bool` | Enables or disables host Git operations. |
| `enable_session_store` | `?bool` | Enables or disables the cross-session store. |
| `create_session_fs_provider` | `?SessionFsProviderFactory` | Creates the filesystem provider for this session. This field is never sent as JSON. |

Optional values preserve presence. `null` omits a field. An explicit `false`,
`""`, `&.{}`, or empty optional nested struct stays in the request as `false`,
an empty string, an empty array, or `{}`. For example,
`.additional_directories = &.{}` sends `"additionalDirectories":[]`, while
`.additional_directories = null` omits that JSON field.

### Register SessionFS

Register SessionFS on the connection before creating or resuming a session.
The minimum registration supplies both paths and the path convention.

```zig
var client = try copilot.Client.init(allocator, io, .{
    .session_fs = .{
        .initial_cwd = "/workspace",
        .session_state_path = ".copilot/session",
        .conventions = .posix,
    },
});
defer client.deinit();
```

Set `.capabilities = .{ .sqlite = true }` only when every session provider
implements the SQLite callbacks. For an extension child process, use
`Client.initParentWithOptions` so `joinParentSession` can register SessionFS on
that connection.

```zig
var client = try copilot.Client.initParentWithOptions(allocator, io, .{
    .session_fs = .{
        .initial_cwd = "/workspace",
        .session_state_path = ".copilot/session",
        .conventions = .posix,
        .capabilities = .{ .sqlite = true },
    },
});
defer client.deinit();
```

The client sends `sessionFs.setProvider` during startup. If the connection has
a SessionFS registration, each create, resume, or join config must set
`create_session_fs_provider`. If the registration declares SQLite support, the
created provider must also set `SessionFsProvider.sqlite`. The lifecycle call
fails before `session.create` or `session.resume` when these values do not
match. A config that sets `create_session_fs_provider` without a connection
registration also fails before the lifecycle RPC.

Create one provider for each session.

```zig
fn createSessionFsProvider(
    allocator: std.mem.Allocator,
    init: copilot.SessionFsProviderInit,
    context: ?*anyopaque,
) !copilot.SessionFsProvider {
    const factory: *FsFactory = @ptrCast(@alignCast(context.?));
    const state = try allocator.create(MySessionFs);
    errdefer allocator.destroy(state);
    state.* = try MySessionFs.init(allocator, init.session_id, factory.root);
    return .{
        .context = state,
        .vtable = &MySessionFs.vtable,
        .sqlite = MySessionFs.sqliteProvider(state),
    };
}

const session = try client.createSession(.{
    .create_session_fs_provider = .{
        .context = &fs_factory,
        .create = createSessionFsProvider,
    },
});
```

`SessionFsProviderInit.session_id` is borrowed for the factory call. The
provider must not retain that slice without copying it. The factory may allocate
provider state with the supplied allocator. `SessionFsProvider.VTable.deinit`
must release that state with the same allocator.

### Implement the SessionFS callbacks

`SessionFsProvider.VTable` defines ten filesystem callbacks:

| Callback | Capability and result |
| --- | --- |
| `read_file` | Reads UTF-8 file content and returns `SessionFsOwnedBytes`. |
| `write_file` | Replaces a file with UTF-8 content and an optional `u64` mode. |
| `append_file` | Appends UTF-8 content with an optional `u64` mode. |
| `exists` | Reports whether a path exists. Callback errors produce `false`. |
| `stat` | Returns file flags, size, and RFC 3339 `mtime` and `birthtime` values. |
| `mkdir` | Creates a directory with `recursive` and an optional `u64` mode. |
| `readdir` | Returns owned entry names in `SessionFsOwnedStrings`. |
| `readdir_with_types` | Returns owned names tagged as `file` or `directory`. |
| `rm` | Removes a path with `recursive` and `force` controls. |
| `rename` | Moves `source` to `destination`. |

`SessionFsSqliteProvider.VTable` adds three callbacks:

| Callback | Capability and result |
| --- | --- |
| `query` | Receives `exec`, `query`, or `run` plus optional named parameters. It returns typed rows, columns, `rows_affected`, and an optional `last_insert_rowid`. |
| `transaction` | Runs typed statements and returns either owned query results or a classified failure. The callback is optional. |
| `exists` | Reports whether the session SQLite database exists. |

Only `SessionFsSqliteParameter.value` and `SessionFsSqliteCell.value` contain
opaque JSON. The statement, query result, row, column, count, last insert ID,
transaction result, and transaction failure class remain typed. Use
`busy_or_locked`, `fatal`, or `post_commit_ambiguous` for a transaction failure.

The adapter takes ownership of every successful callback result. Allocate
`SessionFsOwnedBytes`, `SessionFsOwnedStrings`, `SessionFsOwnedEntries`,
`SessionFsStat`, `SessionFsSqliteQueryResult`, and
`SessionFsSqliteTransactionOutcome` with the callback allocator. The adapter
deinitializes each result after it writes the JSON-RPC response, including write
and validation failures.

### Read the workspace path

`Session.workspacePath()` returns `!?[]const u8`.

```zig
if (try session.workspacePath()) |workspace_path| {
    std.debug.print("workspace: {s}\n", .{workspace_path});
}
```

An active session with no runtime path returns `null`. An inactive handle
returns `error.SessionNotActive`. The returned path is borrowed from the client
and remains valid until disconnect, client deinitialization, or a successful
resident resume replaces the session record.

The client owns the session ID, copied workspace path, and optional SessionFS
provider for each active or disconnected handle. A lifecycle call does not
replace that state until all fallible response processing succeeds. A failed
resident resume therefore preserves the existing state. If processing fails
after a new create or nonresident resume returns a runtime session ID, the
client detaches that runtime session before local cleanup. The client tears down
each provider exactly once while its session ID remains valid.

## Configure extensions

Trusted built-in plugins are installed transactionally after `connect` and
before `Client.init` returns:

```zig
var client = try copilot.Client.init(allocator, io, .{
    .builtin_plugin_directories = &.{"/opt/acme/copilot-plugins"},
});
```

Create, resume, and extension-child join use distinct configuration types.
Their `.extensions.common` bundle supports plugin directories, skill
directories and disabled/built-in skill names, typed hooks, stdio/HTTP/SSE MCP
servers, runtime-managed MCP OAuth, canvas declarations, extension identity,
and the MCP Apps opt-in. Each lifecycle-specific `.extensions` config exposes
`canvas_provider` as a sibling of `.common`; resume and join also expose restored
canvas state. Configuration is validated before a lifecycle RPC.

MCP OAuth uses the pinned runtime's real flow: set
`mcp.on_auth_request`, receive `mcp.oauth_required`, and return an allocated
token or cancellation. Select `.oauth_token_storage = .persistent` to request
OS-keychain storage; the default is runtime-owned in-memory storage.

Canvas and MCP Apps methods fail closed until the create/resume response
advertises their capability. Capability state is `unknown`, `unsupported`, or
`supported`, and live `capabilities.changed` events update it. Use
`snapshotOpenCanvases` for an owned, defensive resume snapshot:

```zig
if (session.capabilities().supports(.canvases)) {
    var opened = try session.openCanvas(allocator, .{
        .canvas_id = "review",
        .instance_id = "review:main",
    });
    defer opened.deinit();
}

const apps = try session.experimental(.mcp_apps);
var tools = try apps.listTools(allocator, "tickets", "tickets");
defer tools.deinit();
```

MCP Apps results are intentionally returned as owned JSON while the pinned
protocol remains experimental. Extension-management acknowledgement and
host-owned OAuth token-store callbacks are not present in the pinned contract;
see `sync/extensibility-contract.json` for the reproducible compatibility
classification.

Use `SessionConfig.available_tools` and `SessionConfig.excluded_tools` to
constrain the model-visible tool set for each created or resumed session. Tool
filters use source-qualified names such as `builtin:ask_user`, `custom:*`, and
`mcp:server-tool`; a bare `*` does not match all sources. The SDK sends
`toolFilterPrecedence: "excluded"` so an exclusion still applies when both
lists are present. Process-level CLI arguments do not replace these
session-level fields in headless SDK mode.

Set `.enable_config_discovery = true` when creating or joining a session to
discover MCP server configurations (`.mcp.json` and `.vscode/mcp.json`) and
skill directories from the working directory. Treat enabling discovery as a
trust decision because discovered MCP servers may be started by the session.
An explicit `false` disables discovery; the default `null` leaves the field
omitted so Copilot CLI applies its default behavior.

Set `.skip_custom_instructions = false` to load filesystem custom instructions.
Set `.enable_on_demand_instruction_discovery = true` to discover `AGENTS.md`,
`CLAUDE.md`, and `.github/copilot-instructions.md` after successful file views.
Both options default to `null`, which leaves their runtime defaults unchanged.

To load skills and custom instructions only from explicit trusted locations,
set `.skill_directories` and `.instruction_directories` instead of enabling
ambient config discovery. Set `.enable_skills = true` to activate skill loading
from the explicit directories. All three fields are omitted when left as
`null`.

### Configure custom agents

Define custom agents on create, resume, or join. Select the initial agent with
`.agent` while keeping the built-in agent policy in `.default_agent`:

```zig
const session = try client.createSession(.{
    .tools = &.{ read_tool, search_tool, deploy_tool },
    .custom_agents = &.{.{
        .name = "reviewer",
        .display_name = "Code reviewer",
        .description = "Reviews changes without deploying them.",
        .tools = &.{ "read", "search" },
        .prompt = "Review the change and report concrete defects.",
        .skills = &.{"code-review"},
        .model = "claude-sonnet-5",
        .reasoning_effort = .high,
    }},
    .default_agent = .{
        .excluded_tools = &.{"deploy"},
    },
    .agent = .{ .custom_agent = "reviewer" },
    .excluded_builtin_agents = &.{"explore"},
});
defer session.disconnect() catch {};
```

A null custom-agent `tools` field inherits the session tools. An empty slice
grants no tools. Null optional slices omit their wire fields, while explicit
empty slices remain empty arrays or maps. The SDK rejects duplicate custom
agent names and an initial custom-agent name that is not in `custom_agents`
before it changes local session state or sends a lifecycle request.

## List available models

`Client.listModels` calls the authenticated `models.list` RPC. The result
includes model IDs and names, capabilities and limits, policy, billing and token
prices, reasoning and context tiers, picker categories, promotions, warnings,
messages, and provider metadata.

```zig
var result = try client.listModels(.{});
defer result.deinit();

for (result.value.models) |model| {
    std.debug.print("{s}: {s}\n", .{ model.id, model.name });
}
```

Pass `selection_id` to use an account returned by the upstream account APIs, or
`github_token` for compatibility with hosts that already own a token.

## Use a custom provider

Set `CreateSessionConfig.provider` for a static custom provider:

```zig
const session = try client.createSession(.{
    .provider = .{
        .base_url = "https://api.openai.com/v1",
        .protocol = .{ .openai = .{ .responses = .http } },
        .authentication = .{ .api_key_and_bearer_token = .{
            .api_key = "provider-api-key",
            .bearer_token = "static-fallback",
        } },
        .headers = &.{
            .{ .name = "X-Tenant", .value = "acme" },
        },
        .model_id = "gpt-4.1",
        .wire_model = "deployment-name",
        .max_prompt_tokens = 100_000,
        .max_context_window_tokens = 128_000,
        .max_output_tokens = 16_384,
    },
});
```

`ProviderConfig.Protocol` supports OpenAI Chat Completions, OpenAI Responses
over HTTP or WebSocket, Azure with an optional API version, and Anthropic.
`Authentication` supports no credentials, one API key, one static bearer
token, or both through `api_key_and_bearer_token`. Credentials are optional for
local providers. A static bearer token takes precedence over an API key.

The SDK rejects empty header names and duplicate names without regard to ASCII
case. It does not parse `base_url`.

Set `bearer_token_provider` when credentials must refresh for each request:

```zig
fn getToken(
    allocator: std.mem.Allocator,
    request: copilot.ProviderTokenRequest,
    context: ?*anyopaque,
) ![]u8 {
    _ = request;
    _ = context;
    return allocator.dupe(u8, "fresh-token");
}

const session = try client.createSession(.{
    .provider = .{
        .base_url = "https://api.example.test",
        .bearer_token_provider = .{
            .callback = getToken,
            .context = null,
        },
    },
});
```

The callback returns a token allocated with the supplied allocator. The SDK
frees the token after it writes the JSON-RPC response. The caller owns the
callback context and must keep it valid until the session disconnects or the
client is deinitialized. A dynamic token takes precedence over a static bearer
token and an API key. Singular providers always use the callback route
`"default"`. `provider_name` only supplies provider attribution.

Use `SessionConfig.providers` and `SessionConfig.models` to add named provider
connections and selectable models:

```zig
const session = try client.createSession(.{
    .model = "internal/reasoner",
    .providers = &.{
        .{
            .name = "internal",
            .base_url = "https://models.example.test",
            .authentication = .{ .bearer_token = "token" },
        },
    },
    .models = &.{
        .{
            .id = "reasoner",
            .provider = "internal",
            .wire_model = "deployment-name",
            .model_id = "gpt-4.1",
        },
    },
});
```

A named model's selectable ID is `provider/id`, such as
`internal/reasoner`. Provider names cannot contain `/`.
Each model must reference one provider in the same configuration. The SDK
rejects duplicate provider names and duplicate qualified model IDs.
`provider` cannot be combined with `providers` or `models`.
Named OpenAI and Azure Responses providers select `.http` or `.websockets`
through their protocol's `responses` value.

Set `CreateSessionConfig.model_capabilities` when a custom model needs capability
overrides, for example to enable image input for a local vision model:

```zig
const session = try client.createSession(.{
    .model = "local-vision-model",
    .provider = .{
        .base_url = "http://localhost:8000/v1",
        .model_id = "local-vision-model",
    },
    .model_capabilities = .{
        .supports = .{ .vision = true },
    },
});
```

Use `Client.resumeSession(session_id, config)` to resume an existing host
session. The former ID-based `joinSession` name was misleading and has been
replaced. Extensions connected with `Client.initParent` use
`joinParentSession(session_id, config)`; its `JoinSessionConfig` deliberately
cannot set `extension_sdk_path`. It returns a `JoinedSession`; its owned
`grants` exposes only approved requested environment values and must be
deinitialized. The deprecated `joinSession(session_id, SessionConfig)` wrapper
remains available for source compatibility and delegates to `resumeSession`.
`ModelCapabilitiesOverride` is a typed deep-partial override: every nested field
is optional. Null fields are omitted so the runtime keeps its defaults; explicit
`false` disables a capability. Overrides do not change the model ID or wire model.
The nested types follow the existing model metadata field names: `ModelSupports`
has `vision`, `reasoningEffort`, and `adaptive_thinking`; `ModelLimitsOverride`
has `max_prompt_tokens`, `max_output_tokens`, `max_context_window_tokens`, and
optional `vision`. `ModelVisionLimitsOverride` has optional
`supported_media_types`, `max_prompt_images`, and `max_prompt_image_size`.
When supplied, `max_prompt_images` must be at least 1; both session APIs return
`error.InvalidMaxPromptImages` for zero before sending an RPC.
Capability overrides require a runtime that supports `modelCapabilities`; they
do not add image support to a text-only model.

`hasBearerTokenProvider` is private wire state derived from
`bearer_token_provider`. Alternate SDK transports and remaining unsupported
event variants are deferred.

## Handle legacy ask_user requests

Set `CreateSessionConfig.on_user_input_request` to enable Copilot's legacy
question-and-answer `ask_user` tool. The handler receives the session ID,
question, optional choices, and optional freeform setting. Its answer must be
allocated with the provided allocator; the SDK frees it after responding.
`UserInputRequest` exposes these values as `session_id`, `question`, `choices`,
and `allow_freeform`; return the allocated `answer` and `was_freeform` in
`UserInputResponse`. Set `user_input_context` to pass handler-specific state.

```zig
const session = try client.createSession(.{
    .on_user_input_request = struct {
        fn handle(
            allocator: std.mem.Allocator,
            request: copilot.UserInputRequest,
            _: ?*anyopaque,
        ) !copilot.UserInputResponse {
            _ = request;
            return .{
                .answer = try allocator.dupe(u8, "Continue"),
                .was_freeform = false,
            };
        }
    }.handle,
});
```

The SDK sends `requestUserInput: true` for session creation and resumption
when this handler is configured, then synchronously dispatches inbound
`userInput.request` RPCs to it.

## Handle permission requests automatically

Set `CreateSessionConfig.on_permission_request` to handle `permission.requested`
events while they are read. Use the prebuilt `copilot.approveAll` handler to
approve ordinary requests without manually responding from the event loop:

```zig
const session = try client.createSession(.{
    .on_permission_request = copilot.approveAll,
});
```

`approveAll` matches the official SDK behavior. It returns an error instead of
approving when either managed-settings source is configured, leaves requests
with `managedApprovalRequired: true` pending, and approves every other valid
request once. The SDK rejects a permission event if
`managedApprovalRequired` is present but is not a boolean.

Managed settings may be fetched by the runtime or injected by the host:

```zig
const session = try client.createSession(.{
    .enable_managed_settings = true,
    .managed_settings = .{
        .permissions = .{
            .deny = &.{"Shell(git push *)"},
            .ask = &.{"Write(**)"},
        },
    },
    .on_permission_request = customPermissionHandler,
});
```

Do not combine `approveAll` with either managed-settings source. Both
`.enable_managed_settings = true` and a non-null `.managed_settings` set
`PermissionInvocation.managed_settings_enabled`, causing `approveAll` to fail
without sending a decision so the request remains available for manual
handling.

Custom handlers receive SDK-owned invocation metadata and the existing opaque
context:

```zig
fn customPermissionHandler(
    request: copilot.PermissionRequested,
    invocation: copilot.PermissionInvocation,
    context: ?*anyopaque,
) !copilot.PermissionDecision {
    _ = context;
    if (invocation.managed_settings_enabled or
        request.managed_approval_required)
    {
        return .no_result;
    }
    return .approve_once;
}
```

Return `.approve_once`, `.{ .reject = "reason" }`, or `.no_result`; use
`.{ .json = "{\"kind\":\"approve-once\"}" }` with
`respondToPermissionJson`'s decision format for advanced upstream decisions.
`permission_context` passes handler-specific state. Configuring a handler
automatically sends `requestPermission: true` on both create and resume, and
the handler must be supplied again when resuming because callbacks are
process-local.

Automatically handled permission events remain observable through
`Session.nextEvent`. Inspect `PermissionRequested.automatic_handling` before
responding manually:

```zig
.permission_requested => |request| switch (request.automatic_handling) {
    .handled => {}, // The automatic response succeeded; do not respond again.
    .not_configured, .no_result, .handler_failed => {
        try handlePermissionManually(session, request);
    },
    .delivery_failed => |err| {
        // Delivery may be indeterminate. Surface or reconcile the failure
        // instead of blindly sending a duplicate response.
        std.log.err("permission response failed: {s}", .{@errorName(err)});
    },
},
```

`.no_result` preserves the request for manual handling.
`.handler_failed` also occurs before any response is attempted and carries the
handler error. `.delivery_failed` carries response preparation, transport, RPC,
or rejection errors; it does not promise that retrying is safe.

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

## RPC coverage

The SDK supports only the stdio transport. Typed high-level methods implement:

- `connect`
- `plugins.builtin.set`
- `session.create`
- `session.resume`
- `session.send`
- `session.abort`
- `session.model.switchTo`
- `models.list`
- `session.model.switchAutoTier`
- `session.log`
- `session.detach`
- `session.event`
- `hooks.invoke`
- `canvas.open`
- `canvas.close`
- `canvas.action.invoke`
- `session.canvas.open`
- `session.canvas.close`
- `session.canvas.action.invoke`
- `session.eventLog.registerInterest`
- `session.eventLog.releaseInterest`
- `session.mcp.oauth.handlePendingRequest`
- `session.mcp.apps.listTools`
- `session.mcp.apps.callTool`
- `session.mcp.apps.readResource`
- `session.permissions.handlePendingPermissionRequest`
- `session.tools.handlePendingToolCall`

`Client.callRpc` is the experimental typed transport escape hatch for every
outbound method in the pinned upstream `server` and `session` RPC scopes. The
caller supplies the expected result type and owns the returned
`std.json.Parsed(Result)`.

`Client.registerRpcHandler` and `unregisterRpcHandler` cover every inbound method
in the pinned upstream `clientGlobal` and `clientSession` scopes. Handlers run
synchronously while the client is reading RPC traffic and must not recursively
call the same client; re-entry returns `error.ReentrantRpcCall`. A successful
handler returns JSON allocated with the allocator passed to it.
The handler receives `null` when the request omitted `params`.

It parses every event discriminator in the pinned schema into an explicit
`SessionEvent` tag with schema-generated public fields. The generated payload
types are available through `SessionEventTypes`. These events retain focused
helpers and compatibility fields:

- `assistant.message`
- `assistant.message_delta`
- `assistant.reasoning`
- `assistant.reasoning_delta`
- `session.idle`
- `session.error`
- `permission.requested`
- `external_tool.requested`

Use `event.rawData()` to read the additional owned canonical `data` JSON for
every parsed event. The `unknown` variant is only for discriminators that are
absent from the pinned schema. Keep an `else` branch in a switch that must
compile after a schema sync adds event tags.

The SDK does not support an external CLI server URL.
`sync/schema-snapshot.json` records every method by direction and scope.
`sync/public-rpc-surface.json` separately records direct RPC calls made by the
pinned upstream Node client and session implementations. The sync checks fail
if either inventory is stale or unclassified. The checks also regenerate the
event registry in memory and reject drift in the union, parser, or cleanup
mapping.

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
