const std = @import("std");
const copilot_sdk = @import("copilot_sdk");

test "external consumer imports root SdkError export" {
    std.debug.print("\nCENSUS_PROBE root_export_compile\n", .{});
    const sdk_error: copilot_sdk.SdkError = error.ProtocolFailure;
    const error_tag_fn: *const fn (*const copilot_sdk.Failure) copilot_sdk.SdkError =
        &copilot_sdk.Failure.errorTag;
    try std.testing.expectEqual(error.ProtocolFailure, sdk_error);
    _ = error_tag_fn;
}
