import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  buildRegistry,
  generateSessionEvents,
  renderSessionEvents,
} from "./generate-session-events.mjs";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const schemaPath = join(root, "vendor", "copilot", "schemas", "session-events.schema.json");

function schema() {
  return JSON.parse(readFileSync(schemaPath, "utf8"));
}

function eventDefinition(value, discriminator) {
  return value.definitions[
    value.definitions.SessionEvent.anyOf.find((entry) => {
      const name = entry.$ref.split("/").at(-1);
      return value.definitions[name].properties.type.const === discriminator;
    }).$ref.split("/").at(-1)
  ];
}

function reachablePayloadDefinitions(value) {
  const seen = new Set();
  function visitNode(node) {
    if (!node || typeof node !== "object") return;
    if (node.$ref) {
      visitDefinition(node.$ref.split("/").at(-1));
      return;
    }
    if (node.properties) Object.values(node.properties).forEach(visitNode);
    if (node.items) visitNode(node.items);
    if (node.anyOf) node.anyOf.forEach(visitNode);
    if (node.additionalProperties && typeof node.additionalProperties === "object") {
      visitNode(node.additionalProperties);
    }
  }
  function visitDefinition(name) {
    if (seen.has(name)) return;
    seen.add(name);
    visitNode(value.definitions[name]);
  }
  for (const event of value.definitions.SessionEvent.anyOf) {
    const eventSchema = value.definitions[event.$ref.split("/").at(-1)];
    visitNode(eventSchema.properties.data);
  }
  return seen;
}

test("the pinned schema renders 140 explicit event tags", () => {
  const value = schema();
  const { entries } = buildRegistry(value);
  const rendered = renderSessionEvents(value);

  assert.equal(entries.length, 140);
  assert.ok(rendered.startsWith("// Generated file. Do not edit directly.\n"));
  assert.doesNotMatch(rendered, /Schema sha256|Discriminators:|Regenerate with:|Source:/);
  assert.match(rendered, /pub const SessionEvent = union\(enum\)/);
  assert.match(rendered, /mcp_oauth_required: McpOauthRequiredEventPayload/);
  assert.match(rendered, /assistant_message: AssistantMessage/);
  assert.match(rendered, /unknown: payloads\.UnknownEvent/);
  assert.doesNotMatch(rendered, /: payloads\.RawEvent,/);
  assert.match(rendered, /pub const StartData = struct/);
  assert.match(rendered, /session_id: \[\]const u8/);
  assert.match(rendered, /pub const PermissionRequest = union\(enum\)/);
});

test("the committed generated registry is current", () => {
  assert.doesNotThrow(() => generateSessionEvents({ check: true }));
});

test("duplicate wire discriminators are rejected", () => {
  const value = schema();
  value.definitions.SessionEvent.anyOf.push(value.definitions.SessionEvent.anyOf[0]);
  assert.throws(
    () => buildRegistry(value),
    /duplicate session event discriminator: session\.start/,
  );
});

test("normalized Zig tag collisions are rejected", () => {
  const value = schema();
  eventDefinition(value, "session.start").properties.type.const = "collision.one";
  eventDefinition(value, "session.resume").properties.type.const = "collision-one";
  assert.throws(
    () => buildRegistry(value),
    /session event tag collision collision_one: collision-one and collision\.one/,
  );
});

test("the reserved unknown tag is rejected", () => {
  const value = schema();
  eventDefinition(value, "session.start").properties.type.const = "unknown";
  assert.throws(
    () => buildRegistry(value),
    /session event discriminator normalizes to reserved tag: unknown/,
  );
});

test("missing rich overrides are rejected", () => {
  const value = schema();
  value.definitions.SessionEvent.anyOf =
    value.definitions.SessionEvent.anyOf.filter((entry) => {
      const name = entry.$ref.split("/").at(-1);
      return value.definitions[name].properties.type.const !== "assistant.message";
    });
  assert.throws(
    () => buildRegistry(value),
    /missing rich session event override: assistant\.message/,
  );
});

test("missing data definitions are rejected", () => {
  const value = schema();
  delete value.definitions.StartData;
  assert.throws(
    () => buildRegistry(value),
    /StartEvent references missing data definition: StartData/,
  );
});

test("unsupported reachable schema constructs fail with their path", () => {
  const value = schema();
  value.definitions.StartData.properties.sessionId.pattern = "^[a-z]+$";
  assert.throws(
    () => buildRegistry(value),
    /unsupported schema keyword pattern at #\/definitions\/StartData\/properties\/sessionId/,
  );
});

test("unreachable definitions are not generated or interpreted", () => {
  const value = schema();
  value.definitions.UnreachableFutureShape = {
    type: "string",
    pattern: "^[a-z]+$",
  };
  const rendered = renderSessionEvents(value);
  assert.doesNotMatch(rendered, /UnreachableFutureShape/);
});

test("every event-reachable definition is emitted as a public type", () => {
  const value = schema();
  const rendered = renderSessionEvents(value);
  for (const name of reachablePayloadDefinitions(value)) {
    assert.match(rendered, new RegExp(`pub const ${name} =`));
  }
});

test("opaque JSON is emitted only for schema-marked values", () => {
  const value = schema();
  const renderedTypes = renderSessionEvents(value).split("fn OwnedPayload", 1)[0];
  let opaqueNodes = 0;
  function countOpaque(node) {
    if (!node || typeof node !== "object") return;
    if (node["x-opaque-json"] === true) opaqueNodes += 1;
    if (node.properties) Object.values(node.properties).forEach(countOpaque);
    if (node.items) countOpaque(node.items);
    if (node.anyOf) node.anyOf.forEach(countOpaque);
    if (node.additionalProperties && typeof node.additionalProperties === "object") {
      countOpaque(node.additionalProperties);
    }
  }
  for (const name of reachablePayloadDefinitions(value)) {
    countOpaque(value.definitions[name]);
  }
  assert.equal(
    [...renderedTypes.matchAll(/std\.json\.Value/g)].length,
    opaqueNodes,
  );

  delete value.definitions.ToolExecutionCompleteData.properties.mcpMeta["x-opaque-json"];
  assert.throws(
    () => renderSessionEvents(value),
    /unsupported schema construct at #\/definitions\/ToolExecutionCompleteData\/properties\/mcpMeta/,
  );
});
