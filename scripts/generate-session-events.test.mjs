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

test("the pinned schema renders 140 explicit event tags", () => {
  const value = schema();
  const registry = buildRegistry(value);
  const rendered = renderSessionEvents(value);

  assert.equal(registry.length, 140);
  assert.match(rendered, /pub const SessionEvent = union\(enum\)/);
  assert.match(rendered, /mcp_oauth_required: payloads\.RawEvent/);
  assert.match(rendered, /assistant_message: payloads\.AssistantMessage/);
  assert.match(rendered, /unknown: payloads\.UnknownEvent/);
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
