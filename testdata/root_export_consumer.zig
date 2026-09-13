const std = @import("std");
const copilot_sdk = @import("copilot_sdk");

test "external consumer imports root SdkError export" {
    std.debug.print("\nCENSUS_PROBE root_export_compile\n", .{});
    const sdk_error: copilot_sdk.SdkError = error.ProtocolFailure;
    const error_tag_fn: *const fn (*const copilot_sdk.Failure) copilot_sdk.SdkError =
        &copilot_sdk.Failure.errorTag;
    try std.testing.expectEqual(error.ProtocolFailure, sdk_error);
    _ = error_tag_fn;
    _ = copilot_sdk.PingResponse;
    _ = copilot_sdk.ClientStatus;
    _ = copilot_sdk.AuthStatus;
    _ = copilot_sdk.SessionId;
    _ = copilot_sdk.SessionListFilter;
    _ = copilot_sdk.SessionContext;
    _ = copilot_sdk.SessionMetadata;
    _ = copilot_sdk.SessionCatalog;
    _ = copilot_sdk.SessionLifecycleType;
    _ = copilot_sdk.SessionLifecycleMetadata;
    _ = copilot_sdk.SessionLifecycleEvent;
    _ = copilot_sdk.SessionLifecycleOverflow;
    _ = copilot_sdk.SessionLifecycleDelivery;
    _ = copilot_sdk.SessionEventHistory;
    _ = copilot_sdk.SessionOperation;
    _ = copilot_sdk.Client.ping;
    _ = copilot_sdk.Client.pingDetailed;
    _ = copilot_sdk.Client.getStatus;
    _ = copilot_sdk.Client.getStatusDetailed;
    _ = copilot_sdk.Client.getAuthStatus;
    _ = copilot_sdk.Client.getAuthStatusDetailed;
    _ = copilot_sdk.Client.getLastSessionId;
    _ = copilot_sdk.Client.getLastSessionIdDetailed;
    _ = copilot_sdk.Client.deleteSession;
    _ = copilot_sdk.Client.deleteSessionDetailed;
    _ = copilot_sdk.Client.listSessions;
    _ = copilot_sdk.Client.listSessionsDetailed;
    _ = copilot_sdk.Client.getSessionMetadata;
    _ = copilot_sdk.Client.getSessionMetadataDetailed;
    _ = copilot_sdk.Client.getForegroundSessionId;
    _ = copilot_sdk.Client.getForegroundSessionIdDetailed;
    _ = copilot_sdk.Client.setForegroundSessionId;
    _ = copilot_sdk.Client.setForegroundSessionIdDetailed;
    _ = copilot_sdk.Client.nextLifecycleEvent;
    _ = copilot_sdk.Client.nextLifecycleEventDetailed;
    _ = copilot_sdk.Session.getEvents;
    _ = copilot_sdk.Session.getEventsDetailed;
}
