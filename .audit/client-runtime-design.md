# Client runtime configuration design

## Selected shape

`ClientOptions` keeps the pre-PR compatibility fields. An optional `connection`
selects a transport, while runtime policy remains client-scoped.

```zig
pub const RuntimeConnection = union(enum) {
    stdio: StdioConnection,
    tcp: TcpConnection,
    uri: UriConnection,
};
```

The connection variants contain only transport data.

```zig
pub const StdioConnection = struct {
    path: []const u8 = "copilot",
    args: []const []const u8 = &.{},
    env: ?[]const EnvironmentVariable = null,
};
```

TCP adds `port` and `token`. URI contains only `url` and `token`.
`ClientOptions` owns mode, directories, logging, environment, authentication,
telemetry, idle timeout, and remote-session enablement. Token plus omitted
login disables logged-in-user fallback. No token plus omitted login enables it.

```zig
pub const ClientOptions = struct {
    cli_path: []const u8 = "copilot",
    working_directory: ?[]const u8 = null,
    cli_args: []const []const u8 = &.{},
    connection_token: ?[]const u8 = null,
    connection: ?RuntimeConnection = null,
    mode: RuntimeMode = .copilot_cli,
    base_directory: ?[]const u8 = null,
    log_level: ?ClientLogLevel = null,
    env: ?[]const EnvironmentVariable = null,
    github_token: ?[]const u8 = null,
    use_logged_in_user: ?bool = null,
    telemetry: ?TelemetryConfig = null,
    session_idle_timeout_seconds: u32 = 0,
    enable_remote_sessions: bool = false,
};
```

The initialized client owns one private transport union. Stdio owns a child and pipes. TCP owns a child and socket. URI owns only a socket. Parent stdio remains an internal variant. Cleanup switches exhaustively on that union.

Client callbacks use separate descriptors and contexts per callback.
Filesystem metadata is client-scoped. Each session config selects a provider
factory. A linear registry stores pending and committed providers by exact
session ID, with pending replacements winning callback routing.

Owned stdio and TCP teardown releases interests, detaches sessions, and requests
`runtime.shutdown` with a ten-second bound while callback state remains alive.
It then closes the transport and unconditionally kills and reaps the child.
URI, parent stdio, and fixtures never receive `runtime.shutdown`.

`RemoteSessionMode` is a typed `.off`, `.@"export"`, or `.on` session option.
Create and resume serialize it as `remoteSession` and omit it when unset.

```zig
pub const SessionFilesystemConfig = struct {
    initial_working_directory: []const u8,
    session_state_path: []const u8,
    conventions: SessionFilesystemConventions,
    capabilities: SessionFilesystemCapabilities = .{},
};

pub const SessionFilesystemProviderFactory = struct {
    handler: *const fn (
        std.mem.Allocator,
        []const u8,
        ?*anyopaque,
    ) anyerror!SessionFilesystemProvider,
    context: ?*anyopaque = null,
};
```

## Compatibility

`Client.init(allocator, io, .{})` remains unchanged. Existing `cli_path`, `working_directory`, `cli_args`, `connection_token`, `client_info`, and `builtin_plugin_directories` fields remain accepted as the implicit stdio shorthand. An explicit connection rejects conflicting legacy transport fields before any process or socket side effect.

## Rejected shapes

- Flat transport flags admit contradictory child, TCP, and URI states.
- Separate public client types duplicate the session and RPC API.
- A public transport vtable leaks framing and lifecycle policy.
- A one-field runtime wrapper adds nesting without ownership value.
- A model-list cache adds synchronization to a blocking client without a required behavior gain.
- A public shutdown report adds API before a consumer requires it.

## Verification contract

- Literal argument and environment lowering for every stable process option.
- Real stdio and TCP fake-runtime round trips.
- URI teardown closes the client socket while the external server remains usable.
- Per-client callback routing with two simultaneous clients.
- Trace context on create, resume, and send.
- Session filesystem request routing, error mapping, and exactly-once cleanup.
- Pending provider routing and resident-resume replacement rollback.
- Bounded owned-runtime shutdown success, RPC failure, and timeout.
- No shutdown request for URI connections.
- Literal `remoteSession` create and resume lowering.
- Failure rollback after spawn, socket connect, handshake, and callback setup.
- Existing `Client.init` call forms compile.
