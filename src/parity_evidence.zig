pub const Evidence = enum {
    fragmented_frame_behavior,
    framing_failure_ownership,
    invalid_json_dispatch,
    invalid_envelope_dispatch,
    session_event_violation_matrix,
    session_agent_delivery,
    failure_constructor_ownership,
    unexpected_response_dispatch,
    server_request_response_matrix,
    permission_tool_delivery_behavior,
    permission_handler_behavior,
    tool_handler_behavior,
    process_exit_dispatch,
    process_write_ownership,
    shutdown_behavior,
    shutdown_dropped_behavior,
    connect_rejection_dispatch,
    protocol_version_dispatch,
    root_export_compile,
};

pub const Kind = enum {
    behavior,
    detailed_behavior,
    ownership,
    compile,
};

pub const Spec = struct {
    id: Evidence,
    source_file: []const u8,
    test_filter: []const u8,
    kind: Kind,
    package_root: ?[]const u8 = null,
};

pub const registry = [_]Spec{
    .{ .id = .fragmented_frame_behavior, .source_file = "src/json_rpc.zig", .test_filter = "fragmented Content-Length framing reads complete body", .kind = .behavior },
    .{ .id = .framing_failure_ownership, .source_file = "src/json_rpc.zig", .test_filter = "empty and malformed framing preserve legacy and detailed diagnostics", .kind = .ownership },
    .{ .id = .invalid_json_dispatch, .source_file = "src/client.zig", .test_filter = "public RPC captures malformed JSON and envelopes", .kind = .detailed_behavior },
    .{ .id = .invalid_envelope_dispatch, .source_file = "src/client.zig", .test_filter = "invalid envelope dispatch retains canonical parseable JSON", .kind = .detailed_behavior },
    .{ .id = .session_event_violation_matrix, .source_file = "src/client.zig", .test_filter = "session.event invalid envelope violation matrix", .kind = .detailed_behavior },
    .{ .id = .session_agent_delivery, .source_file = "src/client.zig", .test_filter = "nextEventDetailed owns complete session diagnostics after frame teardown", .kind = .detailed_behavior },
    .{ .id = .failure_constructor_ownership, .source_file = "src/client.zig", .test_filter = "failure constructors classify owned literal fields and deinit", .kind = .ownership },
    .{ .id = .unexpected_response_dispatch, .source_file = "src/client.zig", .test_filter = "detailed RPC and malformed frame failures own literal payloads", .kind = .detailed_behavior },
    .{ .id = .server_request_response_matrix, .source_file = "src/client.zig", .test_filter = "server request response matrix preserves generic userInput.request fallback", .kind = .behavior },
    .{ .id = .permission_tool_delivery_behavior, .source_file = "src/client.zig", .test_filter = "detailed permission and tool delivery failures retain operation context", .kind = .detailed_behavior },
    .{ .id = .permission_handler_behavior, .source_file = "src/client.zig", .test_filter = "permission handler failures leave requests available for manual handling", .kind = .detailed_behavior },
    .{ .id = .tool_handler_behavior, .source_file = "src/client.zig", .test_filter = "nextEventDetailed reports automatic tool handler failure", .kind = .detailed_behavior },
    .{ .id = .process_exit_dispatch, .source_file = "src/client.zig", .test_filter = "high-level clean EOF preserves legacy framing and detailed process exit", .kind = .detailed_behavior },
    .{ .id = .process_write_ownership, .source_file = "src/client.zig", .test_filter = "process terminate and client write constructors own fields and deinit", .kind = .ownership },
    .{ .id = .shutdown_behavior, .source_file = "src/client.zig", .test_filter = "stopDetailed retains detach RPC failure details and completes cleanup", .kind = .detailed_behavior },
    .{ .id = .shutdown_dropped_behavior, .source_file = "src/client.zig", .test_filter = "stopDetailed reports allocation-free dropped diagnostics", .kind = .detailed_behavior },
    .{ .id = .connect_rejection_dispatch, .source_file = "src/client.zig", .test_filter = "connect rejection preserves legacy and detailed classification", .kind = .detailed_behavior },
    .{ .id = .protocol_version_dispatch, .source_file = "src/client.zig", .test_filter = "connect validates the protocol version", .kind = .detailed_behavior },
    .{ .id = .root_export_compile, .source_file = "testdata/root_export_consumer.zig", .test_filter = "external consumer imports root SdkError export", .kind = .compile, .package_root = "src/root.zig" },
};

pub fn registryIsExhaustive() bool {
    if (registry.len != std.meta.tags(Evidence).len) return false;
    for (std.meta.tags(Evidence)) |tag| {
        var matches: usize = 0;
        for (registry) |spec| {
            if (spec.id == tag) matches += 1;
        }
        if (matches != 1) return false;
    }
    return true;
}

comptime {
    if (!registryIsExhaustive())
        @compileError("every Evidence tag must have exactly one registry entry");
}
const std = @import("std");
