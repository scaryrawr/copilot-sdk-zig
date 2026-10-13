import assert from "node:assert/strict";
import test from "node:test";
import { verifyCustomAgentConfigurationSourceContract } from "./custom-agent-source-contract.mjs";

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

test("custom-agent guards accept pinned fields and declarative agent-local hooks", () => {
  verifyCustomAgentConfigurationSourceContract(source);
  verifyCustomAgentConfigurationSourceContract(withHooks);
});

test("custom-agent guards reject hook and unrelated field drift", () => {
  for (const [before, after] of [
    ["hooks?:", "hooks:"],
    ["Record<string, Record<string, unknown>[]>", "Record<string, unknown>"],
    ["Record<string, Record<string, unknown>[]>", "SessionHooks"],
    ["prompt: string", "prompt?: string"],
    ["tools?: string[] | null", "tools?: string[]"],
    ["name: string;", "name: string; future?: boolean;"],
    ["reasoningEffort?: ReasoningEffort;", ""],
  ]) {
    assert.throws(() => verifyCustomAgentConfigurationSourceContract(
      withHooks.replace(before, after),
    ), /CustomAgentConfig/);
  }
});
