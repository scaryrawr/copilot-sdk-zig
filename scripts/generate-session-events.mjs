import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { sessionEventRegistry } from "./schema-snapshot.mjs";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const schemaPath = join(root, "vendor", "copilot", "schemas", "session-events.schema.json");
const outputPath = join(root, "src", "session_event_generated.zig");

const richOverrides = new Map([
  ["assistant.message", {
    payload: "AssistantMessage",
    parser: "parseAssistantMessage",
    data: { content: "hello", messageId: "message-1" },
    invalidData: { messageId: "message-1" },
  }],
  ["assistant.message_delta", {
    payload: "AssistantMessageDelta",
    parser: "parseAssistantMessageDelta",
    data: { deltaContent: "hello", messageId: "message-1" },
    invalidData: { deltaContent: "hello" },
  }],
  ["assistant.reasoning", {
    payload: "AssistantReasoning",
    parser: "parseAssistantReasoning",
    data: { reasoningId: "reasoning-1", content: "inspect", rte: true },
    invalidData: { reasoningId: "reasoning-1" },
  }],
  ["assistant.reasoning_delta", {
    payload: "AssistantReasoningDelta",
    parser: "parseAssistantReasoningDelta",
    data: { reasoningId: "reasoning-1", deltaContent: "inspect" },
    invalidData: { reasoningId: "reasoning-1" },
  }],
  ["session.idle", {
    payload: "SessionIdle",
    parser: "parseSessionIdle",
    data: { aborted: false, mode: "interactive" },
    invalidData: { aborted: "false" },
  }],
  ["session.error", {
    payload: "SessionError",
    parser: "parseSessionError",
    data: { message: "failed" },
    invalidData: {},
  }],
  ["permission.requested", {
    payload: "PermissionRequested",
    parser: "parsePermissionRequested",
    data: { requestId: "permission-1", permissionRequest: { kind: "shell" } },
    invalidData: { requestId: "permission-1" },
  }],
  ["external_tool.requested", {
    payload: "ExternalToolRequested",
    parser: "parseExternalToolRequested",
    data: {
      requestId: "request-1",
      toolCallId: "tool-call-1",
      toolName: "lookup",
      arguments: { id: "alpha" },
    },
    invalidData: { requestId: "request-1" },
  }],
]);

function zigTag(discriminator) {
  return discriminator.replace(/[^A-Za-z0-9]/g, "_").toLowerCase();
}

function zigString(value) {
  return JSON.stringify(value);
}

export function buildRegistry(schema) {
  const entries = sessionEventRegistry(schema);
  const discriminators = new Map();
  const tags = new Map();

  for (const entry of entries) {
    if (!schema.definitions?.[entry.dataDefinitionName]) {
      throw new Error(
        `${entry.definitionName} references missing data definition: ${entry.dataDefinitionName}`,
      );
    }
    if (discriminators.has(entry.discriminator)) {
      throw new Error(`duplicate session event discriminator: ${entry.discriminator}`);
    }
    discriminators.set(entry.discriminator, entry.definitionName);

    const tag = zigTag(entry.discriminator);
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(tag)) {
      throw new Error(`invalid Zig tag ${tag} for ${entry.discriminator}`);
    }
    if (tag === "unknown") {
      throw new Error(`session event discriminator normalizes to reserved tag: ${entry.discriminator}`);
    }
    const collided = tags.get(tag);
    if (collided) {
      throw new Error(
        `session event tag collision ${tag}: ${collided} and ${entry.discriminator}`,
      );
    }
    tags.set(tag, entry.discriminator);
    entry.tag = tag;
    entry.rich = richOverrides.get(entry.discriminator) ?? null;
  }

  for (const discriminator of richOverrides.keys()) {
    if (!discriminators.has(discriminator)) {
      throw new Error(`missing rich session event override: ${discriminator}`);
    }
  }

  return entries;
}

function renderUnion(entries) {
  const variants = entries.map((entry) =>
    `    ${entry.tag}: payloads.${entry.rich?.payload ?? "RawEvent"},`
  );
  variants.push("    unknown: payloads.UnknownEvent,");
  return variants.join("\n");
}

function renderKnownSwitch(entries, capture, expression) {
  return entries.map((entry) =>
    `            .${entry.tag} => ${capture ? `|${capture}| ` : ""}${expression(entry)},`
  ).join("\n");
}

function renderTagLookup(entries) {
  return entries.map((entry) =>
    `    if (std.mem.eql(u8, wire, ${zigString(entry.discriminator)})) return .${entry.tag};`
  ).join("\n");
}

function renderParseCases(entries) {
  return entries.map((entry) => {
    if (!entry.rich) {
      return `        .${entry.tag} => return .{ .${entry.tag} = raw.take() },`;
    }
    return `        .${entry.tag} => {
            var payload = try payloads.${entry.rich.parser}(allocator, data);
            payload.raw = raw.take();
            return .{ .${entry.tag} = payload };
        },`;
  }).join("\n");
}

function renderRegistryEntries(entries) {
  return entries.map((entry) =>
    `    .{ .wire = ${zigString(entry.discriminator)}, .tag = .${entry.tag} },`
  ).join("\n");
}

function renderSamples(entries) {
  return entries.map((entry) => {
    const json = JSON.stringify({
      type: entry.discriminator,
      data: entry.rich?.data ?? {},
    });
    return `    .{ .json = ${zigString(json)}, .tag = .${entry.tag} },`;
  }).join("\n");
}

function renderMalformedRichSamples(entries) {
  return entries
    .filter((entry) => entry.rich)
    .map((entry) => zigString(JSON.stringify({
      type: entry.discriminator,
      data: entry.rich.invalidData,
    })))
    .map((json) => `    ${json},`)
    .join("\n");
}

export function renderSessionEvents(schema, schemaBytes = Buffer.from(JSON.stringify(schema))) {
  const entries = buildRegistry(schema);
  const digest = createHash("sha256").update(schemaBytes).digest("hex");
  const eventTypes = renderKnownSwitch(
    entries,
    null,
    (entry) => zigString(entry.discriminator),
  );
  const rawData = renderKnownSwitch(
    entries,
    "value",
    (entry) => entry.rich ? "value.raw.data_json" : "value.data_json",
  );
  const deinit = renderKnownSwitch(
    entries,
    "*value",
    (entry) => entry.rich
      ? "value.deinit(allocator)"
      : "value.deinit(allocator)",
  );

  return `// Generated by scripts/generate-session-events.mjs.
// Source: vendor/copilot/schemas/session-events.schema.json
// Schema sha256: ${digest}
// Discriminators: ${entries.length}
// Regenerate with: node scripts/generate-session-events.mjs

const std = @import("std");
const payloads = @import("session_event_payloads.zig");

pub const SessionEvent = union(enum) {
${renderUnion(entries)}

    pub fn eventType(self: SessionEvent) []const u8 {
        return switch (self) {
${eventTypes}
            .unknown => |value| value.event_type,
        };
    }

    pub fn rawData(self: SessionEvent) []const u8 {
        return switch (self) {
${rawData}
            .unknown => |value| value.data_json,
        };
    }

    pub fn deinit(self: *SessionEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
${deinit}
            .unknown => |*value| value.deinit(allocator),
        }
    }
};

pub const SessionEventTag = std.meta.Tag(SessionEvent);

pub const RegistryEntry = struct {
    wire: []const u8,
    tag: SessionEventTag,
};

pub const pinned_discriminators = [_]RegistryEntry{
${renderRegistryEntries(entries)}
};

fn tagFromDiscriminator(wire: []const u8) ?SessionEventTag {
${renderTagLookup(entries)}
    return null;
}

pub fn parseEvent(allocator: std.mem.Allocator, value: std.json.Value) !SessionEvent {
    const object = try payloads.requiredObject(value);
    const wire = try payloads.requiredString(object, "type");
    const data_value: std.json.Value = object.get("data") orelse .{ .object = .empty };
    const data = try payloads.requiredObject(data_value);

    var raw = try payloads.ownRawData(allocator, data_value);
    errdefer raw.deinit(allocator);

    const tag = tagFromDiscriminator(wire) orelse {
        const owned_wire = try allocator.dupe(u8, wire);
        errdefer allocator.free(owned_wire);
        return .{ .unknown = .{
            .event_type = owned_wire,
            .data_json = raw.take().data_json,
        } };
    };

    switch (tag) {
${renderParseCases(entries)}
        .unknown => unreachable,
    }
}

const EventSample = struct {
    json: []const u8,
    tag: SessionEventTag,
};

const pinned_event_samples = [_]EventSample{
${renderSamples(entries)}
};

test "every pinned discriminator parses to its explicit tag" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, ${entries.length}), pinned_event_samples.len);
    for (pinned_event_samples) |sample| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, sample.json, .{});
        defer parsed.deinit();
        var event = try parseEvent(allocator, parsed.value);
        defer event.deinit(allocator);
        try std.testing.expectEqual(sample.tag, std.meta.activeTag(event));
        try std.testing.expectEqualStrings(
            pinned_discriminators[@intFromEnum(sample.tag)].wire,
            event.eventType(),
        );
    }
}

const malformed_rich_event_samples = [_][]const u8{
${renderMalformedRichSamples(entries)}
};

test "every malformed rich event returns an error" {
    const allocator = std.testing.allocator;
    for (malformed_rich_event_samples) |sample| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, sample, .{});
        defer parsed.deinit();
        try std.testing.expectError(
            error.InvalidSessionEvent,
            parseEvent(allocator, parsed.value),
        );
    }
}
`;
}

export function generateSessionEvents({ check = false } = {}) {
  const schemaBytes = readFileSync(schemaPath);
  const schema = JSON.parse(schemaBytes);
  const expected = renderSessionEvents(schema, schemaBytes);
  if (check) {
    const actual = readFileSync(outputPath, "utf8");
    if (actual !== expected) {
      throw new Error("src/session_event_generated.zig is stale; run node scripts/generate-session-events.mjs");
    }
  } else {
    writeFileSync(outputPath, expected);
  }
}

if (resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  if (args.length === 0) {
    generateSessionEvents();
  } else if (args.length === 1 && args[0] === "--check") {
    generateSessionEvents({ check: true });
  } else {
    throw new Error("usage: node scripts/generate-session-events.mjs [--check]");
  }
}
