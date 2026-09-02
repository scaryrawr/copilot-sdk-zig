pub const json_rpc = @import("json_rpc.zig");
pub const client = @import("client.zig");
pub const session = @import("session.zig");

pub const Client = client.Client;
pub const ClientOptions = client.ClientOptions;
pub const Session = client.Session;
pub const SessionConfig = session.SessionConfig;
pub const MessageOptions = session.MessageOptions;
pub const SessionEvent = session.SessionEvent;
pub const AssistantMessage = session.AssistantMessage;
pub const AssistantMessageDelta = session.AssistantMessageDelta;
pub const ExternalToolRequested = session.ExternalToolRequested;
pub const PermissionRequested = session.PermissionRequested;
pub const PermissionRequestKind = session.PermissionRequestKind;
pub const SessionError = session.SessionError;
pub const SystemMessageConfig = session.SystemMessageConfig;
pub const SystemMessageMode = session.SystemMessageMode;
pub const Tool = session.Tool;
pub const UnknownEvent = session.UnknownEvent;

test {
    _ = json_rpc;
    _ = client;
    _ = session;
}
