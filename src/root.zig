pub const json_rpc = @import("json_rpc.zig");
pub const client = @import("client.zig");
pub const session = @import("session.zig");
const provider = @import("provider.zig");

pub const Client = client.Client;
pub const ClientInfo = client.ClientInfo;
pub const ClientOptions = client.ClientOptions;
pub const Session = client.Session;
pub const AutoTier = session.AutoTier;
pub const AutoTierSwitchResult = session.AutoTierSwitchResult;
pub const AutoTierSwitchStatus = session.AutoTierSwitchStatus;
pub const SessionConfig = session.SessionConfig;
pub const ProviderConfig = provider.ProviderConfig;
pub const MessageOptions = session.MessageOptions;
pub const SessionEvent = session.SessionEvent;
pub const AssistantMessage = session.AssistantMessage;
pub const AssistantMessageDelta = session.AssistantMessageDelta;
pub const ExternalToolRequested = session.ExternalToolRequested;
pub const PermissionRequested = session.PermissionRequested;
pub const PermissionRequestKind = session.PermissionRequestKind;
pub const SessionError = session.SessionError;
pub const SessionIdle = session.SessionIdle;
pub const SystemMessageConfig = session.SystemMessageConfig;
pub const SystemMessageMode = session.SystemMessageMode;
pub const Tool = session.Tool;
pub const ToolLoading = session.ToolLoading;
pub const UnknownEvent = session.UnknownEvent;

test {
    _ = json_rpc;
    _ = client;
    _ = session;
    _ = provider;
}
