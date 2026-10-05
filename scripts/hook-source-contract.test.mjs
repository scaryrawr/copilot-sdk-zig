import assert from "node:assert/strict";
import test from "node:test";
import { verifySubagentHooksSourceContract } from "./hook-source-contract.mjs";

const source = `
export interface SubagentStartHookInput extends BaseHookInput {
  transcriptPath: string;
  agentName: string;
  agentDisplayName?: string;
  agentDescription?: string;
}
export interface SubagentStartHookOutput {
  additionalContext?: string;
}
export interface SubagentStopHookInput extends SubagentStartHookInput {
  agentId?: string;
  agentType: string;
  stopReason: "end_turn";
  response: string;
}
export type SubagentStopHookOutput =
  | { decision: "block"; reason: string; modifiedResponse?: string }
  | { decision?: "allow"; reason?: never; modifiedResponse?: string };
`;

test("accepts the pinned subagent hook input and decision contracts", () => {
  verifySubagentHooksSourceContract(source);
  verifySubagentHooksSourceContract(source.replace(
    'decision: "block";',
    '/* block requires a reason */ decision: "block";',
  ));
});

test("rejects subagent hook field, inheritance, and decision drift", () => {
  for (const [before, after] of [
    ["transcriptPath: string", "transcriptPath?: string"],
    ["agentDisplayName?: string", "agentDisplayName: string"],
    ["extends SubagentStartHookInput", "extends BaseHookInput"],
    ['stopReason: "end_turn"', 'stopReason: "end_turn" | "abort"'],
    ["response: string", "response?: string"],
    ["reason: string", "reason?: string"],
    ["reason?: never", "reason?: string"],
    ['decision?: "allow"', 'decision?: "allow" | "block"'],
    ["additionalContext?: string", "additionalContext?: unknown"],
  ]) {
    assert.throws(() => verifySubagentHooksSourceContract(source.replace(before, after)));
  }
});
