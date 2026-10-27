import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { verifyCustomAgentConfigurationSourceContract } from "./custom-agent-source-contract.mjs";
import { requireSourceFragments, zigEnumValues, zigStructFields } from "./source-contract.mjs";

const source = `
export interface CustomAgentConfig {
  name: string;
  displayName?: string;
  description?: string;
  tools?: string[] | null;
  prompt: string;
  mcpServers?: Record<string, MCPServerConfig>;
  infer?: boolean;
  skills?: string[];
  model?: string;
  reasoningEffort?: ReasoningEffort;
}
`;
const withHooks = source.replace(
  "name: string;",
  "hooks?: Record<string, Record<string, unknown>[]>; name: string;",
);
const withModelPolicy = withHooks.replace(
  "model?: string;",
  "model?: string; modelPolicy?: AgentModelPolicy;",
);

test("custom-agent guards accept pinned fields, hooks, and model policy", () => {
  verifyCustomAgentConfigurationSourceContract(source);
  verifyCustomAgentConfigurationSourceContract(withHooks);
  verifyCustomAgentConfigurationSourceContract(withModelPolicy);
});

test("custom-agent guards reject hook, model policy, and unrelated field drift", () => {
  for (const [before, after] of [
    ["hooks?:", "hooks:"],
    ["Record<string, Record<string, unknown>[]>", "Record<string, unknown>"],
    ["Record<string, Record<string, unknown>[]>", "SessionHooks"],
    ["prompt: string", "prompt?: string"],
    ["tools?: string[] | null", "tools?: string[]"],
    ["name: string;", "name: string; future?: boolean;"],
    ["reasoningEffort?: ReasoningEffort;", ""],
    ["modelPolicy?: AgentModelPolicy", "modelPolicy: AgentModelPolicy"],
    ["modelPolicy?: AgentModelPolicy", "modelPolicy?: string"],
    ["modelPolicy?: AgentModelPolicy", 'modelPolicy?: "preferred" | "required"'],
    ["modelPolicy?: AgentModelPolicy", "modelPolicy?: AgentModelPolicy | null"],
  ]) {
    assert.throws(() => verifyCustomAgentConfigurationSourceContract(
      withModelPolicy.replace(before, after),
    ), /CustomAgentConfig/);
  }
});

test("custom-agent model policy reuses the generated pinned wire enum", () => {
  const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
  const events = read("../src/session_event_generated.zig");
  const session = read("../src/session.zig");
  for (const schemaName of ["api", "session-events"]) {
    const schema = JSON.parse(read(`../vendor/copilot/schemas/${schemaName}.schema.json`));
    assert.deepEqual(
      zigEnumValues(events, "AgentModelPolicy").sort(),
      [...schema.definitions.AgentModelPolicy.enum].sort(),
    );
  }
  requireSourceFragments(session, [
    "pub const AgentModelPolicy = session_events.AgentModelPolicy",
  ], "Zig AgentModelPolicy");
  assert.deepEqual(zigStructFields(session, "CustomAgentConfig").model_policy, {
    type: "?AgentModelPolicy",
    default: "null",
  });
});
