const std = @import("std");
const errors = @import("errors.zig");

const manifest_spec = @import("parity_requirements");
const requirements_manifest = manifest_spec.data;

pub const Boundary = enum {
    framing,
    json_envelope,
    session_events,
    rpc,
    server_requests,
    queue,
    permissions,
    tools,
    process_lifecycle,
    shutdown,
    session_lifecycle,
    client,
    protocol_version,
    public_api,
};

pub const CaseId = enum {
    fragmented_frame,
    missing_content_length,
    invalid_content_length,
    frame_too_large,
    truncated_frame,
    invalid_json,
    non_object_envelope,
    invalid_jsonrpc_version,
    missing_response_id,
    invalid_response_id,
    missing_result_and_error,
    result_and_error,
    invalid_error_object,
    invalid_error_code,
    invalid_error_message,
    invalid_request_method,
    session_event_missing_params,
    session_event_malformed_field,
    session_event_invalid_status,
    session_agent_error,
    generic_rpc_rejection,
    missing_session_rpc_rejection,
    session_rpc_rejection,
    unexpected_response,
    unknown_server_request,
    successful_server_request,
    server_handler_error,
    invalid_server_handler_result,
    invalid_user_input_request,
    absent_user_input_handler,
    event_queue_full,
    queue_rpc_rejection,
    invalid_permission_decision,
    permission_handler_error,
    permission_delivery_rejection,
    permission_not_accepted,
    invalid_tool_result,
    tool_handler_error,
    tool_delivery_rejection,
    tool_not_accepted,
    process_spawn,
    process_exit,
    process_terminate,
    transport_read,
    transport_write,
    shutdown_aggregate,
    shutdown_diagnostics_dropped,
    session_detach_failed,
    json_conversion,
    invalid_config,
    connect_rejected,
    reentrant_rpc,
    unsupported_protocol_version,
    invalid_protocol_version,
    root_sdk_error_export,
};

pub const FailureClass = enum {
    process_spawn,
    process_exited,
    process_terminate,
    client_io,
    client_json,
    client_invalid_config,
    client_reentrant_call,
    protocol_missing_content_length,
    protocol_invalid_content_length,
    protocol_frame_too_large,
    protocol_truncated_frame,
    protocol_invalid_json,
    protocol_invalid_envelope,
    protocol_unexpected_response,
    protocol_mismatch,
    rpc,
    session_not_found,
    session_agent,
    session_detach_failed,
    queue_full,
    queue_rejected,
    permission_invalid_decision,
    permission_handler_failed,
    permission_delivery_failed,
    permission_not_accepted,
    tool_invalid_result,
    tool_handler_failed,
    tool_delivery_failed,
    tool_not_accepted,
    shutdown,
};

pub const SuccessClass = enum {
    fragmented_frame,
    server_request_response,
    public_api_export,
};

pub const Outcome = union(enum) {
    success: SuccessClass,
    failure: FailureClass,
    server_response: i64,
};

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
    process_write_ownership,
    shutdown_behavior,
    shutdown_dropped_behavior,
    connect_rejection_dispatch,
    protocol_version_dispatch,
    root_export_compile,
};

pub const Row = struct {
    id: CaseId,
    boundary: Boundary,
    operation: []const u8,
    trigger: []const u8,
    legacy: []const u8,
    detailed: []const u8,
    violation: []const u8,
    retained: []const u8,
    cleanup: []const u8,
    outcome: Outcome,
    evidence: Evidence,
};

const EvidenceSpec = struct {
    id: Evidence,
    source_file: []const u8,
    test_filter: []const u8,
    kind: EvidenceKind,
    package_root: ?[]const u8 = null,
};

const EvidenceKind = enum {
    behavior,
    detailed_behavior,
    ownership,
    compile,
};

const executable_evidence = [_]EvidenceSpec{
    .{ .id = .fragmented_frame_behavior, .source_file = "src/json_rpc.zig", .test_filter = "fragmented Content-Length framing reads complete body", .kind = .behavior },
    .{ .id = .framing_failure_ownership, .source_file = "src/json_rpc.zig", .test_filter = "captured framing failures retain literal input and lengths", .kind = .ownership },
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
    .{ .id = .process_write_ownership, .source_file = "src/client.zig", .test_filter = "process terminate and client write constructors own fields and deinit", .kind = .ownership },
    .{ .id = .shutdown_behavior, .source_file = "src/client.zig", .test_filter = "stopDetailed aggregates owned failures and attempt counts", .kind = .detailed_behavior },
    .{ .id = .shutdown_dropped_behavior, .source_file = "src/client.zig", .test_filter = "stopDetailed reports allocation-free dropped diagnostics", .kind = .detailed_behavior },
    .{ .id = .connect_rejection_dispatch, .source_file = "src/client.zig", .test_filter = "connect rejection preserves legacy and detailed classification", .kind = .detailed_behavior },
    .{ .id = .protocol_version_dispatch, .source_file = "src/client.zig", .test_filter = "connect validates the protocol version", .kind = .detailed_behavior },
    .{ .id = .root_export_compile, .source_file = "testdata/root_export_consumer.zig", .test_filter = "external consumer imports root SdkError export", .kind = .compile, .package_root = "src/root.zig" },
};

const TaxonomyStatus = union(enum) {
    emitted: []const u8,
    nested_runtime_variant: []const u8,
    declared_not_emitted: []const u8,
};

const TaxonomyEntry = struct {
    type_name: []const u8,
    variant: []const u8,
    status: TaxonomyStatus,
};

const taxonomy = [_]TaxonomyEntry{
    .{ .type_name = "FailureDetail", .variant = "process", .status = .{ .emitted = "process_spawn,process_exit,process_terminate" } },
    .{ .type_name = "FailureDetail", .variant = "client", .status = .{ .emitted = "transport_read,transport_write,json_conversion,invalid_config,reentrant_rpc" } },
    .{ .type_name = "FailureDetail", .variant = "protocol", .status = .{ .emitted = "missing_content_length,invalid_content_length,frame_too_large,truncated_frame,invalid_json,non_object_envelope,unexpected_response,unsupported_protocol_version" } },
    .{ .type_name = "FailureDetail", .variant = "rpc", .status = .{ .emitted = "generic_rpc_rejection,session_rpc_rejection" } },
    .{ .type_name = "FailureDetail", .variant = "session", .status = .{ .emitted = "missing_session_rpc_rejection,session_agent_error,session_detach_failed" } },
    .{ .type_name = "FailureDetail", .variant = "queue", .status = .{ .emitted = "event_queue_full,queue_rpc_rejection" } },
    .{ .type_name = "FailureDetail", .variant = "permission", .status = .{ .emitted = "invalid_permission_decision,permission_handler_error,permission_delivery_rejection,permission_not_accepted" } },
    .{ .type_name = "FailureDetail", .variant = "tool", .status = .{ .emitted = "invalid_tool_result,tool_handler_error,tool_delivery_rejection,tool_not_accepted" } },
    .{ .type_name = "FailureDetail", .variant = "shutdown", .status = .{ .emitted = "shutdown_aggregate,shutdown_diagnostics_dropped" } },

    .{ .type_name = "ProcessFailure", .variant = "spawn", .status = .{ .emitted = "process_spawn" } },
    .{ .type_name = "ProcessFailure", .variant = "exited", .status = .{ .emitted = "process_exit" } },
    .{ .type_name = "ProcessFailure", .variant = "terminate", .status = .{ .emitted = "process_terminate" } },
    .{ .type_name = "ProcessExit", .variant = "exited", .status = .{ .emitted = "process_exit" } },
    .{ .type_name = "ProcessExit", .variant = "signal", .status = .{ .nested_runtime_variant = "runtime ProcessExit detail within process_exit" } },
    .{ .type_name = "ProcessExit", .variant = "stopped", .status = .{ .nested_runtime_variant = "runtime ProcessExit detail within process_exit" } },
    .{ .type_name = "ProcessExit", .variant = "unknown", .status = .{ .nested_runtime_variant = "runtime ProcessExit detail within process_exit" } },

    .{ .type_name = "ClientFailure", .variant = "io", .status = .{ .emitted = "transport_read,transport_write" } },
    .{ .type_name = "ClientFailure", .variant = "json", .status = .{ .emitted = "json_conversion" } },
    .{ .type_name = "ClientFailure", .variant = "invalid_config", .status = .{ .emitted = "invalid_config,connect_rejected" } },
    .{ .type_name = "ClientFailure", .variant = "reentrant_call", .status = .{ .emitted = "reentrant_rpc" } },
    .{ .type_name = "ClientFailure", .variant = "request_cancelled", .status = .{ .declared_not_emitted = "cancellation is declared for a future cancellable RPC path" } },
    .{ .type_name = "ClientFailure", .variant = "stop", .status = .{ .declared_not_emitted = "legacy stop aggregation was superseded by ShutdownFailure" } },

    .{ .type_name = "ProtocolFailure", .variant = "missing_content_length", .status = .{ .emitted = "missing_content_length" } },
    .{ .type_name = "ProtocolFailure", .variant = "invalid_content_length", .status = .{ .emitted = "invalid_content_length" } },
    .{ .type_name = "ProtocolFailure", .variant = "frame_too_large", .status = .{ .emitted = "frame_too_large" } },
    .{ .type_name = "ProtocolFailure", .variant = "truncated_frame", .status = .{ .emitted = "truncated_frame" } },
    .{ .type_name = "ProtocolFailure", .variant = "invalid_json", .status = .{ .emitted = "invalid_json" } },
    .{ .type_name = "ProtocolFailure", .variant = "invalid_envelope", .status = .{ .emitted = "non_object_envelope,invalid_jsonrpc_version,missing_response_id,invalid_response_id,missing_result_and_error,result_and_error,invalid_error_object,invalid_error_code,invalid_error_message,invalid_request_method,session_event_missing_params,session_event_malformed_field,session_event_invalid_status" } },
    .{ .type_name = "ProtocolFailure", .variant = "unexpected_response", .status = .{ .emitted = "unexpected_response" } },
    .{ .type_name = "ProtocolFailure", .variant = "mismatch", .status = .{ .emitted = "unsupported_protocol_version,invalid_protocol_version" } },
    .{ .type_name = "ProtocolMismatch", .variant = "unsupported", .status = .{ .emitted = "unsupported_protocol_version" } },
    .{ .type_name = "ProtocolMismatch", .variant = "invalid_server_version", .status = .{ .emitted = "invalid_protocol_version" } },
    .{ .type_name = "ProtocolMismatch", .variant = "changed", .status = .{ .declared_not_emitted = "the negotiated protocol version is immutable after connect" } },

    .{ .type_name = "RpcOperationContext", .variant = "generic", .status = .{ .emitted = "generic_rpc_rejection" } },
    .{ .type_name = "RpcOperationContext", .variant = "session", .status = .{ .emitted = "missing_session_rpc_rejection,session_rpc_rejection" } },
    .{ .type_name = "RpcOperationContext", .variant = "queue", .status = .{ .emitted = "queue_rpc_rejection" } },
    .{ .type_name = "RpcOperationContext", .variant = "permission", .status = .{ .emitted = "permission_delivery_rejection" } },
    .{ .type_name = "RpcOperationContext", .variant = "tool", .status = .{ .emitted = "tool_delivery_rejection" } },

    .{ .type_name = "SessionFailure", .variant = "not_found", .status = .{ .emitted = "missing_session_rpc_rejection" } },
    .{ .type_name = "SessionFailure", .variant = "agent", .status = .{ .emitted = "session_agent_error" } },
    .{ .type_name = "SessionFailure", .variant = "timeout", .status = .{ .declared_not_emitted = "no public operation currently synthesizes a session timeout failure" } },
    .{ .type_name = "SessionFailure", .variant = "send_while_waiting", .status = .{ .declared_not_emitted = "the current send path does not expose this state as a detailed failure" } },
    .{ .type_name = "SessionFailure", .variant = "event_loop_closed", .status = .{ .declared_not_emitted = "event-loop closure currently maps through transport diagnostics" } },
    .{ .type_name = "SessionFailure", .variant = "id_mismatch", .status = .{ .declared_not_emitted = "session creation does not currently emit this detailed variant" } },
    .{ .type_name = "SessionFailure", .variant = "detach_failed", .status = .{ .emitted = "session_detach_failed" } },

    .{ .type_name = "QueueFailure", .variant = "full", .status = .{ .emitted = "event_queue_full" } },
    .{ .type_name = "QueueFailure", .variant = "rejected", .status = .{ .emitted = "queue_rpc_rejection" } },
    .{ .type_name = "PermissionFailure", .variant = "invalid_decision", .status = .{ .emitted = "invalid_permission_decision" } },
    .{ .type_name = "PermissionFailure", .variant = "handler_failed", .status = .{ .emitted = "permission_handler_error" } },
    .{ .type_name = "PermissionFailure", .variant = "delivery_failed", .status = .{ .emitted = "permission_delivery_rejection" } },
    .{ .type_name = "PermissionFailure", .variant = "not_accepted", .status = .{ .emitted = "permission_not_accepted" } },
    .{ .type_name = "ToolFailure", .variant = "invalid_result", .status = .{ .emitted = "invalid_tool_result" } },
    .{ .type_name = "ToolFailure", .variant = "handler_failed", .status = .{ .emitted = "tool_handler_error" } },
    .{ .type_name = "ToolFailure", .variant = "delivery_failed", .status = .{ .emitted = "tool_delivery_rejection" } },
    .{ .type_name = "ToolFailure", .variant = "not_accepted", .status = .{ .emitted = "tool_not_accepted" } },

    .{ .type_name = "EnvelopeViolation", .variant = "non_object", .status = .{ .emitted = "non_object_envelope" } },
    .{ .type_name = "EnvelopeViolation", .variant = "invalid_jsonrpc_version", .status = .{ .emitted = "invalid_jsonrpc_version" } },
    .{ .type_name = "EnvelopeViolation", .variant = "missing_id", .status = .{ .emitted = "missing_response_id" } },
    .{ .type_name = "EnvelopeViolation", .variant = "invalid_id", .status = .{ .emitted = "invalid_response_id" } },
    .{ .type_name = "EnvelopeViolation", .variant = "missing_result_and_error", .status = .{ .emitted = "missing_result_and_error" } },
    .{ .type_name = "EnvelopeViolation", .variant = "result_and_error", .status = .{ .emitted = "result_and_error" } },
    .{ .type_name = "EnvelopeViolation", .variant = "invalid_error_object", .status = .{ .emitted = "invalid_error_object" } },
    .{ .type_name = "EnvelopeViolation", .variant = "invalid_error_code", .status = .{ .emitted = "invalid_error_code" } },
    .{ .type_name = "EnvelopeViolation", .variant = "invalid_error_message", .status = .{ .emitted = "invalid_error_message" } },
    .{ .type_name = "EnvelopeViolation", .variant = "invalid_method", .status = .{ .emitted = "invalid_request_method" } },
    .{ .type_name = "EnvelopeViolation", .variant = "missing_params", .status = .{ .emitted = "session_event_missing_params" } },
    .{ .type_name = "EnvelopeViolation", .variant = "malformed_field_type", .status = .{ .emitted = "session_event_malformed_field" } },
    .{ .type_name = "EnvelopeViolation", .variant = "invalid_session_status", .status = .{ .emitted = "session_event_invalid_status" } },

    .{ .type_name = "SdkError", .variant = "ClientFailure", .status = .{ .emitted = "process_spawn,process_terminate,transport_read,transport_write,shutdown_aggregate,shutdown_diagnostics_dropped,json_conversion,invalid_config,connect_rejected,reentrant_rpc" } },
    .{ .type_name = "SdkError", .variant = "ProcessExited", .status = .{ .emitted = "process_exit" } },
    .{ .type_name = "SdkError", .variant = "ProtocolFailure", .status = .{ .emitted = "missing_content_length,invalid_content_length,frame_too_large,truncated_frame,invalid_json,non_object_envelope,invalid_jsonrpc_version,missing_response_id,invalid_response_id,missing_result_and_error,result_and_error,invalid_error_object,invalid_error_code,invalid_error_message,invalid_request_method,session_event_missing_params,session_event_malformed_field,session_event_invalid_status,unexpected_response" } },
    .{ .type_name = "SdkError", .variant = "ProtocolMismatch", .status = .{ .emitted = "unsupported_protocol_version,invalid_protocol_version" } },
    .{ .type_name = "SdkError", .variant = "RpcRejected", .status = .{ .emitted = "generic_rpc_rejection,session_rpc_rejection" } },
    .{ .type_name = "SdkError", .variant = "SessionNotFound", .status = .{ .emitted = "missing_session_rpc_rejection" } },
    .{ .type_name = "SdkError", .variant = "SessionFailure", .status = .{ .emitted = "session_agent_error,session_detach_failed" } },
    .{ .type_name = "SdkError", .variant = "QueueFailure", .status = .{ .emitted = "event_queue_full,queue_rpc_rejection" } },
    .{ .type_name = "SdkError", .variant = "PermissionFailure", .status = .{ .emitted = "invalid_permission_decision,permission_handler_error,permission_delivery_rejection,permission_not_accepted" } },
    .{ .type_name = "SdkError", .variant = "ToolFailure", .status = .{ .emitted = "invalid_tool_result,tool_handler_error,tool_delivery_rejection,tool_not_accepted" } },
};

const ExplicitCaseCoverage = struct {
    id: CaseId,
    kind: enum { boundary_only, success, public_api },
};

const explicit_case_coverage = [_]ExplicitCaseCoverage{
    .{ .id = .fragmented_frame, .kind = .success },
    .{ .id = .unknown_server_request, .kind = .boundary_only },
    .{ .id = .successful_server_request, .kind = .success },
    .{ .id = .server_handler_error, .kind = .boundary_only },
    .{ .id = .invalid_server_handler_result, .kind = .boundary_only },
    .{ .id = .invalid_user_input_request, .kind = .boundary_only },
    .{ .id = .absent_user_input_handler, .kind = .boundary_only },
    .{ .id = .root_sdk_error_export, .kind = .public_api },
};

pub const rows = [_]Row{
    .{ .id = .fragmented_frame, .boundary = .framing, .operation = "read response or event frame", .trigger = "header and body arrive across fragmented reads", .legacy = "success", .detailed = "success", .violation = "none", .retained = "complete declared body", .cleanup = "caller frees body", .outcome = .{ .success = .fragmented_frame }, .evidence = .fragmented_frame_behavior },
    .{ .id = .missing_content_length, .boundary = .framing, .operation = "read response or event frame", .trigger = "headers omit Content-Length", .legacy = "MissingContentLength", .detailed = "protocol.missing_content_length", .violation = "missing_content_length", .retained = "no owned payload", .cleanup = "Failure.deinit", .outcome = .{ .failure = .protocol_missing_content_length }, .evidence = .framing_failure_ownership },
    .{ .id = .invalid_content_length, .boundary = .framing, .operation = "read response or event frame", .trigger = "Content-Length is not unsigned decimal", .legacy = "InvalidCharacter", .detailed = "protocol.invalid_content_length", .violation = "invalid_content_length", .retained = "literal header value", .cleanup = "Failure.deinit frees value", .outcome = .{ .failure = .protocol_invalid_content_length }, .evidence = .framing_failure_ownership },
    .{ .id = .frame_too_large, .boundary = .framing, .operation = "read response or event frame", .trigger = "declared body exceeds 16 MiB", .legacy = "FrameTooLarge", .detailed = "protocol.frame_too_large", .violation = "frame_too_large", .retained = "declared and maximum lengths", .cleanup = "Failure.deinit", .outcome = .{ .failure = .protocol_frame_too_large }, .evidence = .framing_failure_ownership },
    .{ .id = .truncated_frame, .boundary = .framing, .operation = "read response or event frame", .trigger = "stream ends before declared body length", .legacy = "EndOfStream", .detailed = "protocol.truncated_frame", .violation = "truncated_frame", .retained = "declared and received lengths", .cleanup = "Failure.deinit", .outcome = .{ .failure = .protocol_truncated_frame }, .evidence = .framing_failure_ownership },

    .{ .id = .invalid_json, .boundary = .json_envelope, .operation = "parse inbound frame", .trigger = "body is invalid JSON", .legacy = "JSON parser error", .detailed = "protocol.invalid_json", .violation = "invalid_json", .retained = "parser error name and cause", .cleanup = "Failure.deinit frees message", .outcome = .{ .failure = .protocol_invalid_json }, .evidence = .invalid_json_dispatch },
    .{ .id = .non_object_envelope, .boundary = .json_envelope, .operation = "classify inbound message", .trigger = "top-level JSON is not an object", .legacy = "InvalidJsonRpc", .detailed = "protocol.invalid_envelope", .violation = "non_object", .retained = "canonical inbound JSON", .cleanup = "Failure.deinit frees message_json", .outcome = .{ .failure = .protocol_invalid_envelope }, .evidence = .invalid_envelope_dispatch },
    .{ .id = .invalid_jsonrpc_version, .boundary = .json_envelope, .operation = "classify inbound message", .trigger = "jsonrpc is absent or not 2.0", .legacy = "InvalidJsonRpc", .detailed = "protocol.invalid_envelope", .violation = "invalid_jsonrpc_version", .retained = "canonical inbound JSON", .cleanup = "Failure.deinit frees message_json", .outcome = .{ .failure = .protocol_invalid_envelope }, .evidence = .invalid_envelope_dispatch },
    .{ .id = .missing_response_id, .boundary = .json_envelope, .operation = "classify response", .trigger = "response id is absent", .legacy = "InvalidJsonRpc", .detailed = "protocol.invalid_envelope", .violation = "missing_id", .retained = "canonical inbound JSON", .cleanup = "Failure.deinit frees message_json", .outcome = .{ .failure = .protocol_invalid_envelope }, .evidence = .invalid_envelope_dispatch },
    .{ .id = .invalid_response_id, .boundary = .json_envelope, .operation = "classify response", .trigger = "response id is not a nonnegative u64", .legacy = "InvalidJsonRpc", .detailed = "protocol.invalid_envelope", .violation = "invalid_id", .retained = "canonical inbound JSON", .cleanup = "Failure.deinit frees message_json", .outcome = .{ .failure = .protocol_invalid_envelope }, .evidence = .invalid_envelope_dispatch },
    .{ .id = .missing_result_and_error, .boundary = .json_envelope, .operation = "classify response", .trigger = "response has neither result nor error", .legacy = "MissingResult", .detailed = "protocol.invalid_envelope", .violation = "missing_result_and_error", .retained = "canonical inbound JSON", .cleanup = "Failure.deinit frees message_json", .outcome = .{ .failure = .protocol_invalid_envelope }, .evidence = .invalid_envelope_dispatch },
    .{ .id = .result_and_error, .boundary = .json_envelope, .operation = "classify response", .trigger = "response has result and error", .legacy = "InvalidJsonRpc", .detailed = "protocol.invalid_envelope", .violation = "result_and_error", .retained = "canonical inbound JSON", .cleanup = "Failure.deinit frees message_json", .outcome = .{ .failure = .protocol_invalid_envelope }, .evidence = .invalid_envelope_dispatch },
    .{ .id = .invalid_error_object, .boundary = .json_envelope, .operation = "validate RPC error", .trigger = "error is not an object", .legacy = "InvalidJsonRpc", .detailed = "protocol.invalid_envelope", .violation = "invalid_error_object", .retained = "canonical inbound JSON", .cleanup = "Failure.deinit frees message_json", .outcome = .{ .failure = .protocol_invalid_envelope }, .evidence = .invalid_envelope_dispatch },
    .{ .id = .invalid_error_code, .boundary = .json_envelope, .operation = "validate RPC error", .trigger = "error code is absent or not an integer", .legacy = "InvalidJsonRpc", .detailed = "protocol.invalid_envelope", .violation = "invalid_error_code", .retained = "canonical inbound JSON", .cleanup = "Failure.deinit frees message_json", .outcome = .{ .failure = .protocol_invalid_envelope }, .evidence = .invalid_envelope_dispatch },
    .{ .id = .invalid_error_message, .boundary = .json_envelope, .operation = "validate RPC error", .trigger = "error message is absent or not a string", .legacy = "InvalidJsonRpc", .detailed = "protocol.invalid_envelope", .violation = "invalid_error_message", .retained = "canonical inbound JSON", .cleanup = "Failure.deinit frees message_json", .outcome = .{ .failure = .protocol_invalid_envelope }, .evidence = .invalid_envelope_dispatch },
    .{ .id = .invalid_request_method, .boundary = .json_envelope, .operation = "classify server request", .trigger = "method is not a string", .legacy = "InvalidJsonRpc", .detailed = "protocol.invalid_envelope", .violation = "invalid_method", .retained = "canonical inbound JSON", .cleanup = "Failure.deinit frees message_json", .outcome = .{ .failure = .protocol_invalid_envelope }, .evidence = .invalid_envelope_dispatch },

    .{ .id = .session_event_missing_params, .boundary = .session_events, .operation = "dispatch session.event notification", .trigger = "envelope fields or required event fields such as message content or permission requestId are absent", .legacy = "InvalidJsonRpc for envelope fields; InvalidSessionEvent inside event", .detailed = "protocol.invalid_envelope with the same native error", .violation = "missing_params", .retained = "canonical complete envelope, params, or event", .cleanup = "Failure.deinit frees message_json", .outcome = .{ .failure = .protocol_invalid_envelope }, .evidence = .session_event_violation_matrix },
    .{ .id = .session_event_malformed_field, .boundary = .session_events, .operation = "dispatch session.event notification", .trigger = "envelope or required event fields such as message content or permission requestId have the wrong type", .legacy = "InvalidJsonRpc for envelope fields; InvalidSessionEvent inside event", .detailed = "protocol.invalid_envelope with the same native error", .violation = "malformed_field_type", .retained = "canonical offending params or event", .cleanup = "Failure.deinit frees message_json", .outcome = .{ .failure = .protocol_invalid_envelope }, .evidence = .session_event_violation_matrix },
    .{ .id = .session_event_invalid_status, .boundary = .session_events, .operation = "dispatch session.error event", .trigger = "statusCode is below 0 or above 999", .legacy = "InvalidSessionEvent", .detailed = "protocol.invalid_envelope", .violation = "invalid_session_status", .retained = "canonical offending event", .cleanup = "Failure.deinit frees message_json", .outcome = .{ .failure = .protocol_invalid_envelope }, .evidence = .session_event_violation_matrix },
    .{ .id = .session_agent_error, .boundary = .session_events, .operation = "deliver session.error event", .trigger = "valid session.error arrives", .legacy = "CopilotSessionError", .detailed = "session.agent", .violation = "agent", .retained = "session and provider diagnostics", .cleanup = "Failure.deinit frees all owned fields", .outcome = .{ .failure = .session_agent }, .evidence = .session_agent_delivery },

    .{ .id = .generic_rpc_rejection, .boundary = .rpc, .operation = "generic RPC", .trigger = "server returns a valid JSON-RPC error", .legacy = "JsonRpcError", .detailed = "rpc", .violation = "rejected", .retained = "method, id, code, message, machine code, data", .cleanup = "Failure.deinit frees RPC fields", .outcome = .{ .failure = .rpc }, .evidence = .failure_constructor_ownership },
    .{ .id = .missing_session_rpc_rejection, .boundary = .rpc, .operation = "join or resume session", .trigger = "server error identifies a missing session", .legacy = "JsonRpcError", .detailed = "session.not_found", .violation = "not_found", .retained = "session id and complete RPC failure", .cleanup = "Failure.deinit frees nested RPC", .outcome = .{ .failure = .session_not_found }, .evidence = .failure_constructor_ownership },
    .{ .id = .session_rpc_rejection, .boundary = .rpc, .operation = "ordinary session RPC", .trigger = "server rejects a non-missing session operation", .legacy = "JsonRpcError", .detailed = "rpc with session context", .violation = "rejected", .retained = "session id and complete RPC failure", .cleanup = "Failure.deinit frees RPC fields", .outcome = .{ .failure = .rpc }, .evidence = .failure_constructor_ownership },
    .{ .id = .unexpected_response, .boundary = .rpc, .operation = "await RPC response", .trigger = "response id differs from request id", .legacy = "UnexpectedResponse", .detailed = "protocol.unexpected_response", .violation = "unexpected_response", .retained = "expected id and canonical actual id", .cleanup = "Failure.deinit frees actual id JSON", .outcome = .{ .failure = .protocol_unexpected_response }, .evidence = .unexpected_response_dispatch },

    .{ .id = .unknown_server_request, .boundary = .server_requests, .operation = "dispatch unregistered server request", .trigger = "method has no registered handler", .legacy = "no local Failure", .detailed = "no local Failure", .violation = "method_not_found", .retained = "JSON-RPC response only", .cleanup = "response buffer freed after write", .outcome = .{ .server_response = -32601 }, .evidence = .server_request_response_matrix },
    .{ .id = .successful_server_request, .boundary = .server_requests, .operation = "dispatch registered server request", .trigger = "handler returns valid JSON", .legacy = "success", .detailed = "success", .violation = "none", .retained = "JSON-RPC result response only", .cleanup = "handler and response buffers freed after write", .outcome = .{ .success = .server_request_response }, .evidence = .server_request_response_matrix },
    .{ .id = .server_handler_error, .boundary = .server_requests, .operation = "dispatch registered server request", .trigger = "handler returns an error", .legacy = "no local Failure", .detailed = "no local Failure", .violation = "handler_error", .retained = "JSON-RPC response only", .cleanup = "response buffer freed after write", .outcome = .{ .server_response = -32000 }, .evidence = .server_request_response_matrix },
    .{ .id = .invalid_server_handler_result, .boundary = .server_requests, .operation = "dispatch registered server request", .trigger = "handler result is not JSON", .legacy = "no local Failure", .detailed = "no local Failure", .violation = "invalid_handler_result", .retained = "JSON-RPC response only", .cleanup = "handler and response buffers freed after write", .outcome = .{ .server_response = -32603 }, .evidence = .server_request_response_matrix },
    .{ .id = .invalid_user_input_request, .boundary = .server_requests, .operation = "dispatch userInput.request", .trigger = "params cannot decode as user input", .legacy = "no local Failure", .detailed = "no local Failure", .violation = "invalid_user_input_request", .retained = "JSON-RPC response only", .cleanup = "temporary JSON and response freed after write", .outcome = .{ .server_response = -32602 }, .evidence = .server_request_response_matrix },
    .{ .id = .absent_user_input_handler, .boundary = .server_requests, .operation = "dispatch userInput.request", .trigger = "decoded session has no registered handler", .legacy = "no local Failure", .detailed = "no local Failure", .violation = "handler_not_registered", .retained = "JSON-RPC response only", .cleanup = "temporary JSON and response freed after write", .outcome = .{ .server_response = -32000 }, .evidence = .server_request_response_matrix },

    .{ .id = .event_queue_full, .boundary = .queue, .operation = "queue session event", .trigger = "queue reaches 1024 entries", .legacy = "EventQueueFull", .detailed = "queue.full", .violation = "full", .retained = "session id, event type, length, capacity", .cleanup = "Failure.deinit frees optional strings", .outcome = .{ .failure = .queue_full }, .evidence = .failure_constructor_ownership },
    .{ .id = .queue_rpc_rejection, .boundary = .queue, .operation = "deliver queued operation", .trigger = "server rejects queue RPC", .legacy = "JsonRpcError", .detailed = "queue.rejected", .violation = "rejected", .retained = "queue context and complete RPC failure", .cleanup = "Failure.deinit frees RPC fields", .outcome = .{ .failure = .queue_rejected }, .evidence = .failure_constructor_ownership },

    .{ .id = .invalid_permission_decision, .boundary = .permissions, .operation = "validate permission decision", .trigger = "decision JSON or shape is invalid", .legacy = "InvalidPermissionDecision", .detailed = "permission.invalid_decision", .violation = "invalid_decision", .retained = "session id, request id, message, cause", .cleanup = "Failure.deinit frees owned fields", .outcome = .{ .failure = .permission_invalid_decision }, .evidence = .permission_tool_delivery_behavior },
    .{ .id = .permission_handler_error, .boundary = .permissions, .operation = "automatic permission handler", .trigger = "handler returns an error", .legacy = "handler error", .detailed = "permission.handler_failed", .violation = "handler_failed", .retained = "session id, request id, cause", .cleanup = "Failure.deinit frees owned fields", .outcome = .{ .failure = .permission_handler_failed }, .evidence = .permission_handler_behavior },
    .{ .id = .permission_delivery_rejection, .boundary = .permissions, .operation = "deliver permission decision", .trigger = "server rejects delivery RPC", .legacy = "JsonRpcError", .detailed = "permission.delivery_failed", .violation = "delivery_failed", .retained = "permission context and complete RPC failure", .cleanup = "Failure.deinit frees RPC fields", .outcome = .{ .failure = .permission_delivery_failed }, .evidence = .permission_tool_delivery_behavior },
    .{ .id = .permission_not_accepted, .boundary = .permissions, .operation = "deliver permission decision", .trigger = "server returns accepted=false", .legacy = "PermissionDecisionNotAccepted", .detailed = "permission.not_accepted", .violation = "not_accepted", .retained = "session id, request id, message", .cleanup = "Failure.deinit frees owned fields", .outcome = .{ .failure = .permission_not_accepted }, .evidence = .permission_tool_delivery_behavior },

    .{ .id = .invalid_tool_result, .boundary = .tools, .operation = "validate tool result", .trigger = "tool result JSON or shape is invalid", .legacy = "InvalidToolResult", .detailed = "tool.invalid_result", .violation = "invalid_result", .retained = "session id, request id, tool identity, message, cause", .cleanup = "Failure.deinit frees owned fields", .outcome = .{ .failure = .tool_invalid_result }, .evidence = .permission_tool_delivery_behavior },
    .{ .id = .tool_handler_error, .boundary = .tools, .operation = "automatic tool handler", .trigger = "handler returns an error", .legacy = "handler error", .detailed = "tool.handler_failed", .violation = "handler_failed", .retained = "session id, request id, tool identity, cause", .cleanup = "Failure.deinit frees owned fields", .outcome = .{ .failure = .tool_handler_failed }, .evidence = .tool_handler_behavior },
    .{ .id = .tool_delivery_rejection, .boundary = .tools, .operation = "deliver tool result", .trigger = "server rejects delivery RPC", .legacy = "JsonRpcError", .detailed = "tool.delivery_failed", .violation = "delivery_failed", .retained = "tool context and complete RPC failure", .cleanup = "Failure.deinit frees RPC fields", .outcome = .{ .failure = .tool_delivery_failed }, .evidence = .permission_tool_delivery_behavior },
    .{ .id = .tool_not_accepted, .boundary = .tools, .operation = "deliver tool result", .trigger = "server returns accepted=false", .legacy = "ToolResultNotAccepted", .detailed = "tool.not_accepted", .violation = "not_accepted", .retained = "session id, request id, optional tool id, message", .cleanup = "Failure.deinit frees owned fields", .outcome = .{ .failure = .tool_not_accepted }, .evidence = .permission_tool_delivery_behavior },

    .{ .id = .process_spawn, .boundary = .process_lifecycle, .operation = "spawn CLI", .trigger = "process spawn fails", .legacy = "spawn error", .detailed = "process.spawn", .violation = "spawn", .retained = "executable, message, cause", .cleanup = "Failure.deinit frees owned fields", .outcome = .{ .failure = .process_spawn }, .evidence = .failure_constructor_ownership },
    .{ .id = .process_exit, .boundary = .process_lifecycle, .operation = "read CLI output", .trigger = "child exits before another frame", .legacy = "EndOfStream", .detailed = "process.exited", .violation = "exited", .retained = "exit kind, code, message", .cleanup = "Failure.deinit frees message", .outcome = .{ .failure = .process_exited }, .evidence = .failure_constructor_ownership },
    .{ .id = .process_terminate, .boundary = .process_lifecycle, .operation = "stop client", .trigger = "child termination fails", .legacy = "termination error", .detailed = "process.terminate inside shutdown", .violation = "terminate", .retained = "optional exit, message, cause", .cleanup = "Failure.deinit frees owned message", .outcome = .{ .failure = .process_terminate }, .evidence = .process_write_ownership },
    .{ .id = .transport_read, .boundary = .process_lifecycle, .operation = "read CLI output", .trigger = "transport read fails while child remains live", .legacy = "read error", .detailed = "client.io", .violation = "io", .retained = "read operation, message, cause", .cleanup = "Failure.deinit frees message", .outcome = .{ .failure = .client_io }, .evidence = .failure_constructor_ownership },
    .{ .id = .transport_write, .boundary = .process_lifecycle, .operation = "write CLI input", .trigger = "transport write fails", .legacy = "write error", .detailed = "client.io", .violation = "io", .retained = "write operation, message, cause", .cleanup = "Failure.deinit frees message", .outcome = .{ .failure = .client_io }, .evidence = .process_write_ownership },

    .{ .id = .shutdown_aggregate, .boundary = .shutdown, .operation = "stop client", .trigger = "disconnect or termination attempts fail", .legacy = "first shutdown error", .detailed = "shutdown aggregate", .violation = "aggregate", .retained = "attempt counts and captured failures", .cleanup = "Failure.deinit recursively frees failures", .outcome = .{ .failure = .shutdown }, .evidence = .shutdown_behavior },
    .{ .id = .shutdown_diagnostics_dropped, .boundary = .shutdown, .operation = "stop client", .trigger = "diagnostic storage cannot retain every failure", .legacy = "first shutdown error", .detailed = "shutdown aggregate", .violation = "diagnostics_dropped", .retained = "attempt counts and dropped count", .cleanup = "Failure.deinit handles empty storage", .outcome = .{ .failure = .shutdown }, .evidence = .shutdown_dropped_behavior },
    .{ .id = .session_detach_failed, .boundary = .session_lifecycle, .operation = "disconnect session", .trigger = "detach remains unaccepted after retries", .legacy = "SessionDetachFailed", .detailed = "session.detach_failed", .violation = "detach_failed", .retained = "session id, attempts, optional RPC and message", .cleanup = "Failure.deinit frees nested fields", .outcome = .{ .failure = .session_detach_failed }, .evidence = .failure_constructor_ownership },

    .{ .id = .json_conversion, .boundary = .client, .operation = "encode request or decode result", .trigger = "JSON conversion fails", .legacy = "JSON conversion error", .detailed = "client.json", .violation = "json", .retained = "operation, message, cause", .cleanup = "Failure.deinit frees message", .outcome = .{ .failure = .client_json }, .evidence = .failure_constructor_ownership },
    .{ .id = .invalid_config, .boundary = .client, .operation = "create or resume session", .trigger = "configuration validation fails", .legacy = "InvalidArgument", .detailed = "client.invalid_config", .violation = "invalid_config", .retained = "field and message", .cleanup = "Failure.deinit frees owned fields", .outcome = .{ .failure = .client_invalid_config }, .evidence = .failure_constructor_ownership },
    .{ .id = .connect_rejected, .boundary = .client, .operation = "connect", .trigger = "CLI returns ok=false", .legacy = "ConnectRejected", .detailed = "client.invalid_config", .violation = "connect_rejected", .retained = "literal rejection message", .cleanup = "Failure.deinit frees message", .outcome = .{ .failure = .client_invalid_config }, .evidence = .connect_rejection_dispatch },
    .{ .id = .reentrant_rpc, .boundary = .client, .operation = "call RPC from callback", .trigger = "handler starts a nested RPC", .legacy = "ReentrantRpcCall", .detailed = "client.reentrant_call", .violation = "reentrant_call", .retained = "method and message", .cleanup = "Failure.deinit frees owned fields", .outcome = .{ .failure = .client_reentrant_call }, .evidence = .failure_constructor_ownership },

    .{ .id = .unsupported_protocol_version, .boundary = .protocol_version, .operation = "connect", .trigger = "server version is outside the supported version", .legacy = "ProtocolVersionMismatch", .detailed = "protocol.mismatch.unsupported", .violation = "unsupported", .retained = "server, minimum, maximum", .cleanup = "Failure.deinit", .outcome = .{ .failure = .protocol_mismatch }, .evidence = .protocol_version_dispatch },
    .{ .id = .invalid_protocol_version, .boundary = .protocol_version, .operation = "connect", .trigger = "server version is not a nonnegative integer", .legacy = "ProtocolVersionMismatch", .detailed = "protocol.mismatch.invalid_server_version", .violation = "invalid_server_version", .retained = "canonical server value JSON", .cleanup = "Failure.deinit frees server JSON", .outcome = .{ .failure = .protocol_mismatch }, .evidence = .protocol_version_dispatch },

    .{ .id = .root_sdk_error_export, .boundary = .public_api, .operation = "import copilot_sdk root module", .trigger = "consumer names copilot_sdk.SdkError", .legacy = "success", .detailed = "success", .violation = "none", .retained = "SdkError type identity", .cleanup = "none", .outcome = .{ .success = .public_api_export }, .evidence = .root_export_compile },
};

pub const Stats = struct {
    missing: usize = 0,
    fabricated: usize = 0,
    integrity_errors: usize = 0,
    taxonomy_triples: usize = 0,
    row_probe_references: usize = 0,
    taxonomy_emitted: usize = 0,
    taxonomy_declared_not_emitted: usize = 0,
};

const Requirement = struct {
    id: []const u8,
    boundary: Boundary,
    context: []const u8,
};

fn validIdentifier(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '_')) return false;
    }
    return true;
}

fn parseRequirements(input: []const u8, storage: []Requirement) ![]const Requirement {
    var lines = std.mem.splitScalar(u8, input, '\n');
    if (!std.mem.eql(u8, lines.next() orelse return error.MalformedRequirements, "case_id\tboundary\tcontext"))
        return error.MalformedRequirements;

    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const id = fields.next() orelse return error.MalformedRequirements;
        const boundary_name = fields.next() orelse return error.MalformedRequirements;
        const context = fields.next() orelse return error.MalformedRequirements;
        if (fields.next() != null or !validIdentifier(id) or context.len == 0)
            return error.MalformedRequirements;
        const boundary = std.meta.stringToEnum(Boundary, boundary_name) orelse
            return error.MalformedRequirements;
        for (storage[0..count]) |existing| {
            if (std.mem.eql(u8, existing.id, id)) return error.DuplicateRequirement;
        }
        if (count == storage.len) return error.TooManyRequirements;
        storage[count] = .{ .id = id, .boundary = boundary, .context = context };
        count += 1;
    }
    if (count == 0) return error.MalformedRequirements;
    return storage[0..count];
}

fn requirementFor(requirements: []const Requirement, id: []const u8) ?Requirement {
    for (requirements) |requirement| {
        if (std.mem.eql(u8, requirement.id, id)) return requirement;
    }
    return null;
}

fn evidenceSpec(evidence: Evidence) ?EvidenceSpec {
    for (executable_evidence) |candidate| {
        if (candidate.id == evidence) return candidate;
    }
    return null;
}

fn taxonomyHasVariant(comptime T: type, variant: []const u8) bool {
    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, variant)) return true;
    }
    return false;
}

fn knownTaxonomyVariant(type_name: []const u8, variant: []const u8) bool {
    if (std.mem.eql(u8, type_name, "FailureDetail")) return taxonomyHasVariant(errors.FailureDetail, variant);
    if (std.mem.eql(u8, type_name, "ProcessFailure")) return taxonomyHasVariant(errors.ProcessFailure, variant);
    if (std.mem.eql(u8, type_name, "ProcessExit")) return taxonomyHasVariant(errors.ProcessExit, variant);
    if (std.mem.eql(u8, type_name, "ClientFailure")) return taxonomyHasVariant(errors.ClientFailure, variant);
    if (std.mem.eql(u8, type_name, "ProtocolFailure")) return taxonomyHasVariant(errors.ProtocolFailure, variant);
    if (std.mem.eql(u8, type_name, "ProtocolMismatch")) return taxonomyHasVariant(errors.ProtocolMismatch, variant);
    if (std.mem.eql(u8, type_name, "RpcOperationContext")) return taxonomyHasVariant(errors.RpcOperationContext, variant);
    if (std.mem.eql(u8, type_name, "SessionFailure")) return taxonomyHasVariant(errors.SessionFailure, variant);
    if (std.mem.eql(u8, type_name, "QueueFailure")) return taxonomyHasVariant(errors.QueueFailure, variant);
    if (std.mem.eql(u8, type_name, "PermissionFailure")) return taxonomyHasVariant(errors.PermissionFailure, variant);
    if (std.mem.eql(u8, type_name, "ToolFailure")) return taxonomyHasVariant(errors.ToolFailure, variant);
    if (std.mem.eql(u8, type_name, "EnvelopeViolation")) return taxonomyHasVariant(errors.EnvelopeViolation, variant);
    if (std.mem.eql(u8, type_name, "SdkError")) return taxonomyHasVariant(errors.SdkError, variant);
    return false;
}

fn idListContains(case_ids: []const u8, id: []const u8) bool {
    var ids = std.mem.splitScalar(u8, case_ids, ',');
    while (ids.next()) |candidate| {
        if (std.mem.eql(u8, candidate, id)) return true;
    }
    return false;
}

fn idListCount(case_ids: []const u8, id: []const u8) usize {
    var count: usize = 0;
    var ids = std.mem.splitScalar(u8, case_ids, ',');
    while (ids.next()) |candidate| {
        if (std.mem.eql(u8, candidate, id)) count += 1;
    }
    return count;
}

fn taxonomyReferencesCase(type_name: ?[]const u8, variant: ?[]const u8, id: CaseId) bool {
    for (taxonomy) |entry| {
        if (type_name) |expected_type| {
            if (!std.mem.eql(u8, entry.type_name, expected_type)) continue;
        }
        if (variant) |expected_variant| {
            if (!std.mem.eql(u8, entry.variant, expected_variant)) continue;
        }
        switch (entry.status) {
            .emitted => |case_ids| {
                if (idListContains(case_ids, @tagName(id))) return true;
            },
            .nested_runtime_variant, .declared_not_emitted => {},
        }
    }
    return false;
}

fn explicitlyCoversCase(id: CaseId) bool {
    for (explicit_case_coverage) |entry| {
        if (entry.id == id) return true;
    }
    return false;
}

fn accountTaxonomyType(
    comptime T: type,
    type_name: []const u8,
    requirements: []const Requirement,
    result: *Stats,
) void {
    inline for (std.meta.fields(T)) |field| {
        var matches: usize = 0;
        for (taxonomy) |entry| {
            if (std.mem.eql(u8, entry.type_name, type_name) and
                std.mem.eql(u8, entry.variant, field.name))
            {
                matches += 1;
                switch (entry.status) {
                    .emitted => |case_ids| {
                        if (case_ids.len == 0) {
                            result.integrity_errors += 1;
                        } else {
                            var ids = std.mem.splitScalar(u8, case_ids, ',');
                            while (ids.next()) |id| {
                                result.taxonomy_triples += 1;
                                if (requirementFor(requirements, id) == null)
                                    result.integrity_errors += 1;
                            }
                            result.taxonomy_emitted += 1;
                        }
                    },
                    .nested_runtime_variant => |reason| {
                        if (reason.len == 0) result.integrity_errors += 1;
                        result.taxonomy_emitted += 1;
                    },
                    .declared_not_emitted => |reason| {
                        if (reason.len == 0) result.integrity_errors += 1;
                        result.taxonomy_declared_not_emitted += 1;
                    },
                }
            }
        }
        if (matches != 1) result.integrity_errors += 1;
    }
}

pub fn stats() !Stats {
    var requirement_storage: [256]Requirement = undefined;
    const requirements = try parseRequirements(requirements_manifest, &requirement_storage);
    var result = Stats{};
    for (requirements) |required| {
        var matches: usize = 0;
        for (rows) |row| {
            if (std.mem.eql(u8, @tagName(row.id), required.id)) {
                matches += 1;
                if (row.boundary != required.boundary or
                    !std.mem.eql(u8, row.operation, required.context))
                {
                    result.integrity_errors += 1;
                }
            }
        }
        if (matches == 0) result.missing += 1;
        if (matches > 1) result.fabricated += matches - 1;
    }
    for (rows) |row| {
        if (requirementFor(requirements, @tagName(row.id)) == null) result.fabricated += 1;
    }
    for (std.meta.tags(Evidence)) |required| {
        var matches: usize = 0;
        for (executable_evidence) |spec| {
            if (spec.id == required) {
                matches += 1;
                if (spec.source_file.len == 0 or spec.test_filter.len == 0)
                    result.integrity_errors += 1;
            }
        }
        if (matches != 1) result.integrity_errors += 1;
    }
    for (executable_evidence, 0..) |spec, index| {
        for (executable_evidence[index + 1 ..]) |other| {
            if (std.mem.eql(u8, spec.source_file, other.source_file) and
                std.mem.eql(u8, spec.test_filter, other.test_filter))
            {
                result.integrity_errors += 1;
            }
        }
    }
    for (rows) |row| {
        const fields_present = row.operation.len != 0 and row.trigger.len != 0 and
            row.legacy.len != 0 and row.detailed.len != 0 and row.violation.len != 0 and
            row.retained.len != 0 and row.cleanup.len != 0;
        const evidence = evidenceSpec(row.evidence);
        const evidence_supported = if (evidence) |spec| switch (row.outcome) {
            .failure => spec.kind == .ownership or spec.kind == .detailed_behavior,
            .success, .server_response => spec.kind != .ownership,
        } else false;
        const outcome_supported = switch (row.outcome) {
            .success => row.evidence == .fragmented_frame_behavior or
                row.evidence == .server_request_response_matrix or
                row.evidence == .root_export_compile,
            .server_response => row.evidence == .server_request_response_matrix,
            .failure => row.evidence != .server_request_response_matrix and
                row.evidence != .root_export_compile,
        };
        const claims_success = std.mem.eql(u8, row.legacy, "success") or
            std.mem.eql(u8, row.detailed, "success");
        const success_consistent = switch (row.outcome) {
            .success => std.mem.eql(u8, row.legacy, "success") and
                std.mem.eql(u8, row.detailed, "success"),
            else => !claims_success,
        };
        if (!fields_present or !evidence_supported or !outcome_supported or !success_consistent) {
            result.integrity_errors += 1;
        } else {
            result.row_probe_references += 1;
        }
        if (row.outcome == .failure and row.outcome.failure == .protocol_invalid_envelope) {
            const violation = std.meta.stringToEnum(errors.EnvelopeViolation, row.violation);
            if (violation == null or
                !taxonomyReferencesCase(
                    "EnvelopeViolation",
                    if (violation) |value| @tagName(value) else null,
                    row.id,
                ))
            {
                result.integrity_errors += 1;
            }
        }
        if (!taxonomyReferencesCase(null, null, row.id) and !explicitlyCoversCase(row.id))
            result.integrity_errors += 1;
    }
    for (explicit_case_coverage, 0..) |entry, index| {
        for (explicit_case_coverage[index + 1 ..]) |other| {
            if (entry.id == other.id) result.integrity_errors += 1;
        }
        const row = for (rows) |candidate| {
            if (candidate.id == entry.id) break candidate;
        } else {
            result.integrity_errors += 1;
            continue;
        };
        const valid_kind = switch (entry.kind) {
            .boundary_only => row.outcome == .server_response,
            .success => row.outcome == .success,
            .public_api => row.boundary == .public_api,
        };
        if (!valid_kind) result.integrity_errors += 1;
    }

    for (taxonomy) |entry| {
        if (!knownTaxonomyVariant(entry.type_name, entry.variant))
            result.integrity_errors += 1;
        if ((std.mem.eql(u8, entry.type_name, "EnvelopeViolation") or
            std.mem.eql(u8, entry.type_name, "SdkError")) and
            entry.status == .declared_not_emitted)
        {
            result.integrity_errors += 1;
        }
    }
    for (taxonomy, 0..) |entry, index| {
        var type_seen = false;
        for (taxonomy[0..index]) |prior| {
            if (std.mem.eql(u8, prior.type_name, entry.type_name)) {
                type_seen = true;
                break;
            }
        }
        if (type_seen) continue;
        for (std.meta.tags(CaseId)) |id| {
            var references: usize = 0;
            for (taxonomy) |candidate| {
                if (!std.mem.eql(u8, candidate.type_name, entry.type_name)) continue;
                switch (candidate.status) {
                    .emitted => |case_ids| {
                        references += idListCount(case_ids, @tagName(id));
                    },
                    .nested_runtime_variant, .declared_not_emitted => {},
                }
            }
            if (references > 1) result.integrity_errors += references - 1;
        }
    }
    for (std.meta.tags(CaseId)) |id| {
        if (!taxonomyReferencesCase(null, null, id) and !explicitlyCoversCase(id))
            result.integrity_errors += 1;
    }
    accountTaxonomyType(errors.FailureDetail, "FailureDetail", requirements, &result);
    accountTaxonomyType(errors.ProcessFailure, "ProcessFailure", requirements, &result);
    accountTaxonomyType(errors.ProcessExit, "ProcessExit", requirements, &result);
    accountTaxonomyType(errors.ClientFailure, "ClientFailure", requirements, &result);
    accountTaxonomyType(errors.ProtocolFailure, "ProtocolFailure", requirements, &result);
    accountTaxonomyType(errors.ProtocolMismatch, "ProtocolMismatch", requirements, &result);
    accountTaxonomyType(errors.RpcOperationContext, "RpcOperationContext", requirements, &result);
    accountTaxonomyType(errors.SessionFailure, "SessionFailure", requirements, &result);
    accountTaxonomyType(errors.QueueFailure, "QueueFailure", requirements, &result);
    accountTaxonomyType(errors.PermissionFailure, "PermissionFailure", requirements, &result);
    accountTaxonomyType(errors.ToolFailure, "ToolFailure", requirements, &result);
    accountTaxonomyType(errors.EnvelopeViolation, "EnvelopeViolation", requirements, &result);
    accountTaxonomyType(errors.SdkError, "SdkError", requirements, &result);
    return result;
}

pub fn validateRows() !void {
    var requirement_storage: [256]Requirement = undefined;
    const requirements = try parseRequirements(requirements_manifest, &requirement_storage);
    if (requirements.len != manifest_spec.expected_required_row_count or
        rows.len != manifest_spec.expected_required_row_count)
    {
        return error.CensusRequiredRowAnchorChanged;
    }
    if (executable_evidence.len != manifest_spec.expected_unique_evidence_command_count)
        return error.CensusEvidenceCommandAnchorChanged;
    const result = try stats();
    if (result.missing != 0) return error.CensusMissingRequiredCase;
    if (result.fabricated != 0) return error.CensusFabricatedCase;
    if (result.integrity_errors != 0) return error.CensusIntegrityError;
    if (result.row_probe_references != rows.len) return error.CensusProbeReferenceGap;
}

pub fn printReport(writer: *std.Io.Writer) !void {
    inline for (std.meta.tags(Boundary)) |boundary| {
        var count: usize = 0;
        for (rows) |row| {
            if (row.boundary == boundary) count += 1;
        }
        try writer.print("CENSUS_COUNT {s} {d}\n", .{ @tagName(boundary), count });
    }
    const result = try stats();
    try writer.print("CENSUS_TOTAL {d}\n", .{rows.len});
    try writer.print("CENSUS_MISSING {d}\n", .{result.missing});
    try writer.print("CENSUS_FABRICATED {d}\n", .{result.fabricated});
    try writer.print("CENSUS_INTEGRITY_ERRORS {d}\n", .{result.integrity_errors});
    try writer.print("CENSUS_ROW_PROBE_REFERENCES {d}\n", .{result.row_probe_references});
    try writer.print("CENSUS_TAXONOMY_EMITTED {d}\n", .{result.taxonomy_emitted});
    try writer.print(
        "CENSUS_TAXONOMY_DECLARED_NOT_EMITTED {d}\n",
        .{result.taxonomy_declared_not_emitted},
    );
    try writer.print("CENSUS_TAXONOMY_TRIPLES {d}\n", .{result.taxonomy_triples});
    inline for (.{ "EnvelopeViolation", "SdkError" }) |type_name| {
        var emitted: usize = 0;
        var not_emitted: usize = 0;
        for (taxonomy) |entry| {
            if (!std.mem.eql(u8, entry.type_name, type_name)) continue;
            switch (entry.status) {
                .emitted, .nested_runtime_variant => emitted += 1,
                .declared_not_emitted => not_emitted += 1,
            }
        }
        try writer.print("CENSUS_TAXONOMY {s} {d} {d}\n", .{
            type_name,
            emitted,
            not_emitted,
        });
    }
    try writer.print("CENSUS_UNIQUE_EVIDENCE_COMMANDS {d}\n", .{executable_evidence.len});
    for (rows) |row| {
        try writer.print(
            "CENSUS_MAPPING\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t",
            .{
                @tagName(row.id),
                @tagName(row.boundary),
                row.operation,
                row.trigger,
                row.legacy,
                row.detailed,
                row.violation,
                row.retained,
                row.cleanup,
            },
        );
        switch (row.outcome) {
            .success => |value| try writer.print("success.{s}\n", .{@tagName(value)}),
            .failure => |value| try writer.print("failure.{s}\n", .{@tagName(value)}),
            .server_response => |value| try writer.print("server_response.{d}\n", .{value}),
        }
    }
    for (executable_evidence) |spec| {
        try writer.print(
            "CENSUS_TEST\t{s}\t{s}\t{s}\t{s}\t{s}\n",
            .{
                @tagName(spec.id),
                spec.source_file,
                @tagName(spec.kind),
                spec.test_filter,
                spec.package_root orelse "",
            },
        );
    }
}

test "parity census manifest and taxonomy accounting are valid" {
    try validateRows();
}

test "requirements parser rejects duplicate and malformed rows" {
    var storage: [4]Requirement = undefined;
    try std.testing.expectError(
        error.DuplicateRequirement,
        parseRequirements(
            "case_id\tboundary\tcontext\nsame\tclient\tone\nsame\tclient\ttwo\n",
            &storage,
        ),
    );
    try std.testing.expectError(
        error.MalformedRequirements,
        parseRequirements(
            "case_id\tboundary\tcontext\nbad\tunknown\tcontext\n",
            &storage,
        ),
    );
    try std.testing.expectError(
        error.MalformedRequirements,
        parseRequirements(
            "case_id\tboundary\tcontext\nmissing\tclient\n",
            &storage,
        ),
    );
}

pub fn main() !void {
    try validateRows();
    var output: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer output.deinit();
    try printReport(&output.writer);
    std.debug.print("{s}", .{output.written()});
}
