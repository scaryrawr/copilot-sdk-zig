import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { verifyWorkflowOptionsSourceContract } from "./workflow-source-contract.mjs";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const read = (path) => readFileSync(join(root, path), "utf8");
const api = JSON.parse(read("vendor/copilot/schemas/api.schema.json"));
const events = JSON.parse(read("vendor/copilot/schemas/session-events.schema.json"));

const expectedMethods = [
  "session.workflow.run",
  "session.workflow.resume",
  "session.workflow.runFromTool",
  "session.workflow.resumeFromTool",
  "session.workflow.getRun",
  "session.workflow.listRuns",
  "session.workflow.getRunDetail",
  "session.workflow.getRunProgress",
  "session.workflow.pause",
  "session.workflow.cancel",
  "session.workflow.agent",
  "session.workflow.journal.get",
  "session.workflow.journal.put",
  "session.workflow.pauseAtCheckpoint",
  "session.workflow.log",
  "workflow.execute",
  "workflow.abort",
];

function rpcMethods(value, output = new Map()) {
  if (value && typeof value === "object") {
    if (typeof value.rpcMethod === "string") output.set(value.rpcMethod, value);
    Object.values(value).forEach((child) => rpcMethods(child, output));
  }
  return output;
}

test("the pinned workflow wire methods and ownership fields are exact", () => {
  const methods = rpcMethods(api);
  assert.deepEqual(
    [...methods.keys()]
      .filter((name) => name.startsWith("session.workflow.") || name.startsWith("workflow."))
      .sort(),
    [...expectedMethods].sort(),
  );
  for (const [name, fields] of [
    ["workflow.execute", ["sessionId", "name", "runId", "executionToken", "args"]],
    ["workflow.abort", ["sessionId", "runId", "executionToken"]],
    ["session.workflow.agent", ["sessionId", "workflowRunId", "executionToken", "prompt", "opts"]],
    ["session.workflow.journal.get", ["sessionId", "runId", "executionToken", "key"]],
    ["session.workflow.journal.put", ["sessionId", "runId", "executionToken", "key", "resultJson"]],
    ["session.workflow.pauseAtCheckpoint", ["sessionId", "runId", "executionToken", "key"]],
  ]) {
    assert.deepEqual(Object.keys(methods.get(name).params.properties).sort(), fields.sort());
    assert.deepEqual([...methods.get(name).params.required].sort(), fields.sort());
  }
  assert.deepEqual(api.definitions.WorkflowResumeResult.required.sort(), ["run", "workflowName"]);
  assert.equal(api.definitions.WorkflowRunSummary.properties.workflowName.type, "string");
  assert.equal(api.definitions.WorkflowRunDetail.properties.workflowName.type, "string");
  assert.equal(methods.has("session.factory.run"), false);
  assert.equal(methods.has("factory.execute"), false);
});

test("workflow results and limit overrides preserve wire presence", () => {
  assert.deepEqual(api.definitions.WorkflowRunResult.required, ["runId", "status"]);
  assert.equal(
    api.definitions.WorkflowRunResult.properties.pauseInfo.$ref,
    "#/definitions/WorkflowPauseInfo",
  );
  assert.equal(api.definitions.WorkflowExecuteResult.required, undefined);
  assert.equal(api.definitions.WorkflowAgentResult.required, undefined);
  assert.equal(api.definitions.WorkflowJournalGetResult.properties.resultJson["x-opaque-json"], true);
  assert.deepEqual(api.definitions.WorkflowJournalGetResult.required, ["hit"]);
  for (const field of [
    "maxConcurrentSubagents", "maxTotalSubagents", "maxAiCredits", "timeoutSeconds",
  ]) {
    const value = api.definitions.WorkflowRunLimits.properties[field];
    assert(Array.isArray(value.type) && value.type.includes("null"), field);
    assert(!api.definitions.WorkflowRunLimits.required?.includes(field), field);
  }
  const failureTypes = api.definitions.WorkflowRunFailure.anyOf.map(
    (branch) => branch.properties.type.const,
  ).sort();
  assert.deepEqual(failureTypes, [
    "workflow_accounting_incomplete",
    "workflow_durable_failure",
    "workflow_limit_reached",
    "workflow_provider_disconnected",
    "workflow_resume_declined",
  ]);
});

const workflowOptionsSource = `
export interface WorkflowRunOptions<TArgs extends JsonValue = JsonValue> {
  args?: TArgs;
  limits?: WorkflowLimitOverrides;
  notifyOnComplete?: boolean;
  logPhaseNames?: boolean;
}
export interface WorkflowResumeOptions {
  limits?: WorkflowLimitOverrides;
  notifyOnComplete?: boolean;
  logPhaseNames?: boolean;
}
`;

test("workflow option parity checks the owning run and resume declarations", () => {
  const zigSource = read("src/workflow.zig");
  assert.doesNotThrow(() =>
    verifyWorkflowOptionsSourceContract(workflowOptionsSource, zigSource)
  );
  for (const declaration of ["WorkflowRunOptions", "WorkflowResumeOptions"]) {
    const position = workflowOptionsSource.indexOf("{", workflowOptionsSource.indexOf(declaration));
    const withLegacyField =
      workflowOptionsSource.slice(0, position + 1) +
      "\n  resumeFromRunId?: string;" +
      workflowOptionsSource.slice(position + 1);
    assert.throws(
      () => verifyWorkflowOptionsSourceContract(withLegacyField, zigSource),
      new RegExp(`${declaration} fields changed`),
    );
    const before = workflowOptionsSource.slice(0, position);
    const after = workflowOptionsSource.slice(position);
    for (const [from, to, message] of [
      ["notifyOnComplete?: boolean;", "", "fields changed"],
      ["limits?: WorkflowLimitOverrides;", "limits?: number;", "limits changed"],
      ["logPhaseNames?: boolean;", "logPhaseNames: boolean;", "logPhaseNames changed"],
    ]) {
      assert.throws(
        () => verifyWorkflowOptionsSourceContract(before + after.replace(from, to), zigSource),
        new RegExp(`${declaration}[ .]${message}`),
      );
    }
    const zigPosition = zigSource.indexOf("{", zigSource.indexOf(`pub const ${declaration} =`));
    const withZigLegacyField =
      zigSource.slice(0, zigPosition + 1) +
      "\n    resume_from_run_id: ?[]const u8 = null," +
      zigSource.slice(zigPosition + 1);
    assert.throws(
      () => verifyWorkflowOptionsSourceContract(workflowOptionsSource, withZigLegacyField),
      new RegExp(`Zig ${declaration} fields changed`),
    );
  }
});

test("workflow events use the current vocabulary", () => {
  const discriminators = events.definitions.SessionEvent.anyOf.map(
    (branch) => events.definitions[branch.$ref.split("/").at(-1)].properties.type.const,
  );
  for (const name of [
    "workflow.run_started", "workflow.run_updated", "workflow.run_settled",
  ]) assert(discriminators.includes(name), name);
  assert(!discriminators.some((name) => name.startsWith("factory.")));
  const generated = read("src/session_event_generated.zig");
  assert.match(generated, /workflow_run_id: \?\[\]const u8/);
  assert.match(generated, /workflow_completed: SystemNotificationWorkflowCompleted/);
  assert.match(generated, /workflow: PermissionRequestWorkflow/);
});

test("the breaking Zig workflow API has no factory aliases", () => {
  const exports = read("src/root.zig");
  for (const name of [
    "WorkflowDefinition", "WorkflowContext", "WorkflowRun", "WorkflowApi",
    "WorkflowMeta", "WorkflowDeclaredLimits", "WorkflowLimitOverrides",
    "WorkflowRunsPage", "WorkflowRunDetail", "WorkflowProgressPage",
  ]) assert.match(exports, new RegExp(`pub const ${name} =`));
  assert.doesNotMatch(exports, /pub const (?:AgentFactory|Factory\w*)\b/);
  assert(!existsSync(join(root, "src/factory.zig")));
  assert.match(read("src/client.zig"), /pub fn workflow\(self: Session\) WorkflowApi/);
  assert.doesNotMatch(read("src/client.zig"), /pub fn factory(?:\(|[A-Z])/);
  assert.match(read("src/extensibility.zig"), /workflows: \?\[\]const workflow\.WorkflowDefinition/);
  assert.doesNotMatch(read("src/extensibility.zig"), /\bfactories:/);
  assert.doesNotMatch(read("src/workflow.zig"), /resume_from_run_id/);
  assert.match(exports, /pub const SessionFilesystemProviderFactory = runtime\.SessionFilesystemProviderFactory/);
});
