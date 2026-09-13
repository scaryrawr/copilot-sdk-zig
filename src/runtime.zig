const std = @import("std");
const models = @import("models.zig");

pub const EnvironmentVariable = struct {
    name: []const u8,
    value: []const u8,
};

pub const RuntimeMode = enum {
    copilot_cli,
    empty,
};

pub const ClientLogLevel = enum {
    none,
    error_level,
    warning,
    info,
    debug,
    all,

    pub fn wireValue(self: ClientLogLevel) []const u8 {
        return switch (self) {
            .none => "none",
            .error_level => "error",
            .warning => "warning",
            .info => "info",
            .debug => "debug",
            .all => "all",
        };
    }
};

pub const TelemetryConfig = struct {
    otlp_endpoint: ?[]const u8 = null,
    otlp_protocol: ?enum { http_json, http_protobuf } = null,
    file_path: ?[]const u8 = null,
    exporter_type: ?[]const u8 = null,
    source_name: ?[]const u8 = null,
    capture_content: ?bool = null,
};

pub const StdioConnection = struct {
    path: []const u8 = "copilot",
    args: []const []const u8 = &.{},
    env: ?[]const EnvironmentVariable = null,
};

pub const TcpConnection = struct {
    path: []const u8 = "copilot",
    args: []const []const u8 = &.{},
    env: ?[]const EnvironmentVariable = null,
    port: u16 = 0,
    token: ?[]const u8 = null,
};

pub const UriConnection = struct {
    url: []const u8,
    token: ?[]const u8 = null,
};

pub const RuntimeConnection = union(enum) {
    stdio: StdioConnection,
    tcp: TcpConnection,
    uri: UriConnection,
};

pub const TraceContext = struct {
    traceparent: ?[]const u8 = null,
    tracestate: ?[]const u8 = null,
};

pub const TraceContextCallback = struct {
    handler: *const fn (?*anyopaque) anyerror!TraceContext,
    context: ?*anyopaque = null,
};

pub const ModelListCallback = struct {
    handler: *const fn (
        std.mem.Allocator,
        ?*anyopaque,
    ) anyerror!std.json.Parsed(models.ModelList),
    context: ?*anyopaque = null,
};

pub const SessionFilesystemConventions = enum {
    posix,
    windows,
};

pub const SessionFilesystemFileInfo = struct {
    is_file: bool,
    is_directory: bool,
    size: u64,
    mtime: []const u8,
    birthtime: []const u8,
};

pub const SessionFilesystemEntryType = enum {
    file,
    directory,
};

pub const SessionFilesystemEntry = struct {
    name: []const u8,
    entry_type: SessionFilesystemEntryType,
};

pub const SessionFilesystemReadDirectoryResult = struct {
    entries: []const []const u8,
};

pub const SessionFilesystemReadDirectoryWithTypesResult = struct {
    entries: []const SessionFilesystemEntry,
};

pub const SessionFilesystemSqliteQueryType = enum {
    exec,
    query,
    run,
};

pub const SessionFilesystemSqliteQueryResult = struct {
    columns: []const []const u8 = &.{},
    rows: []const std.json.Value = &.{},
    rows_affected: u64 = 0,
    last_insert_rowid: ?i64 = null,
};

pub const SessionFilesystemSqliteStatement = struct {
    query_type: SessionFilesystemSqliteQueryType,
    query: []const u8,
    params: ?std.json.Value = null,
};

pub const SessionFilesystemSqliteTransactionErrorClass = enum {
    busy_or_locked,
    fatal,
    post_commit_ambiguous,
};

pub const SessionFilesystemSqliteTransactionError = struct {
    error_class: SessionFilesystemSqliteTransactionErrorClass,
    message: []const u8,
};

pub const SessionFilesystemSqliteTransactionResult = struct {
    results: []const SessionFilesystemSqliteQueryResult = &.{},
    @"error": ?SessionFilesystemSqliteTransactionError = null,
};

pub const SessionFilesystemSqliteProvider = struct {
    query: *const fn (
        std.mem.Allocator,
        SessionFilesystemSqliteQueryType,
        []const u8,
        ?std.json.Value,
        ?*anyopaque,
    ) anyerror!std.json.Parsed(SessionFilesystemSqliteQueryResult),
    transaction: ?*const fn (
        std.mem.Allocator,
        []const SessionFilesystemSqliteStatement,
        ?*anyopaque,
    ) anyerror!std.json.Parsed(SessionFilesystemSqliteTransactionResult) = null,
    exists: *const fn (?*anyopaque) anyerror!bool,
};

pub const SessionFilesystemProvider = struct {
    context: ?*anyopaque = null,
    read_file: *const fn (std.mem.Allocator, []const u8, ?*anyopaque) anyerror![]u8,
    write_file: *const fn ([]const u8, []const u8, ?u32, ?*anyopaque) anyerror!void,
    append_file: *const fn ([]const u8, []const u8, ?u32, ?*anyopaque) anyerror!void,
    exists: *const fn ([]const u8, ?*anyopaque) anyerror!bool,
    stat: *const fn ([]const u8, ?*anyopaque) anyerror!SessionFilesystemFileInfo,
    make_directory: *const fn ([]const u8, bool, ?u32, ?*anyopaque) anyerror!void,
    read_directory: *const fn (
        std.mem.Allocator,
        []const u8,
        ?*anyopaque,
    ) anyerror!std.json.Parsed(SessionFilesystemReadDirectoryResult),
    read_directory_with_types: *const fn (
        std.mem.Allocator,
        []const u8,
        ?*anyopaque,
    ) anyerror!std.json.Parsed(SessionFilesystemReadDirectoryWithTypesResult),
    remove: *const fn ([]const u8, bool, bool, ?*anyopaque) anyerror!void,
    rename: *const fn ([]const u8, []const u8, ?*anyopaque) anyerror!void,
    sqlite: ?SessionFilesystemSqliteProvider = null,
    deinit: ?*const fn (?*anyopaque) void = null,
};

pub const SessionFilesystemCapabilities = struct {
    sqlite: bool = false,
};

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

test "runtime connection keeps child-only settings out of URI" {
    const connection = RuntimeConnection{ .uri = .{
        .url = "localhost:4321",
        .token = "secret",
    } };
    try std.testing.expectEqualStrings("localhost:4321", connection.uri.url);
}
