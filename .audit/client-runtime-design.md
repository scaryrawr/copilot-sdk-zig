# Client runtime configuration design

## Selected shape

`ClientOptions` keeps its existing fields so current named initializers compile. A new optional `connection` selects a `RuntimeConnection` union.

```zig
pub const RuntimeConnection = union(enum) {
    stdio: StdioConnection,
    tcp: TcpConnection,
    uri: UriConnection,
};
```

Stdio and TCP contain a shared child-runtime value. URI contains only an address and optional connection token. Child-only process settings cannot be constructed for URI.

```zig
pub const ChildRuntime = struct {
    executable: []const u8 = "copilot",
    args: []const []const u8 = &.{},
    working_directory: ?[]const u8 = null,
    mode: RuntimeMode = .copilot_cli,
    base_directory: ?[]const u8 = null,
    log_level: ?ClientLogLevel = null,
    environment: ?[]const EnvironmentVariable = null,
    authentication: RuntimeAuthentication = .default,
    telemetry: ?TelemetryConfig = null,
    session_idle_timeout_seconds: u32 = 0,
    enable_remote_sessions: bool = false,
};
```

`RuntimeAuthentication` is a tagged union that represents default behavior, logged-in user only, token only, token plus logged-in user, and disabled authentication. Raw environment entries cannot override typed SDK-owned variables.

The initialized client owns one private transport union. Stdio owns a child and pipes. TCP owns a child and socket. URI owns only a socket. Parent stdio remains an internal variant. Cleanup switches exhaustively on that union.

Client callbacks use separate descriptors and contexts per callback. Model-list results retain the existing `std.json.Parsed(models.ModelList)` ownership contract. Trace context is collected for create, resume, and send. Session filesystem configuration creates isolated provider state per attached session and lowers callback failures at the JSON-RPC boundary.

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
- Failure rollback after spawn, socket connect, handshake, and callback setup.
- Existing `Client.init` call forms compile.
