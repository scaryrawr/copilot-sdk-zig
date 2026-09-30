import net from "node:net";
import { writeFileSync } from "node:fs";

const args = process.argv.slice(2);
const pidPathIndex = args.indexOf("--pid-path");
if (pidPathIndex >= 0) {
    writeFileSync(args[pidPathIndex + 1], String(process.pid));
}
const shutdownPathIndex = args.indexOf("--shutdown-path");
const shutdownPath =
    shutdownPathIndex >= 0 ? args[shutdownPathIndex + 1] : null;
const shutdownFsPathIndex = args.indexOf("--shutdown-fs-path");
const shutdownFsPath =
    shutdownFsPathIndex >= 0 ? args[shutdownFsPathIndex + 1] : null;
const announceDelayIndex = args.indexOf("--announce-delay-ms");
const announceDelayMs =
    announceDelayIndex >= 0 ? Number(args[announceDelayIndex + 1]) : 0;
const announceOffsetIndex = args.indexOf("--announce-port-offset");
const announcePortOffset =
    announceOffsetIndex >= 0 ? Number(args[announceOffsetIndex + 1]) : 0;
const managedEnvironmentKeys = [
    "COPILOT_SDK_AUTH_TOKEN",
    "COPILOT_CONNECTION_TOKEN",
    "COPILOT_HOME",
    "COPILOT_DISABLE_KEYTAR",
    "COPILOT_OTEL_ENABLED",
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "OTEL_EXPORTER_OTLP_PROTOCOL",
    "COPILOT_OTEL_FILE_EXPORTER_PATH",
    "COPILOT_OTEL_EXPORTER_TYPE",
    "COPILOT_OTEL_SOURCE_NAME",
    "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT",
    "TEST_RUNTIME_VALUE",
];
const observedEnvironment = Object.fromEntries(
    managedEnvironmentKeys
        .filter((key) => process.env[key] !== undefined)
        .map((key) => [key, process.env[key]])
);
let lastRequest = null;
let workflowExercise = null;
let workflowResult = null;
let hungWorkflowAgentId = null;
let markHungWorkflowAgentReady;
const hungWorkflowAgentReady = new Promise((resolve) => {
    markHungWorkflowAgentReady = resolve;
});
let workflowAbortSent = false;
let nextRequestId = 10_000;
let activeConnections = 0;
const requests = [];
let failNextOptionsUpdate = false;

function workflowSummary() {
    return {
        runId: "run-1",
        workflowName: "demo",
        description: "Demo workflow",
        status: "paused",
        revision: 2,
        createdAt: 1,
        startedAt: 1,
        updatedAt: 2,
        completedAt: null,
        currentPhase: null,
        declaredPhaseCount: 0,
        liveAgentCount: 0,
        totalSpawnedAgentCount: 0,
        consumed: { activeMs: 1, subagents: 0, nanoAiu: 0 },
        declaredLimits: {},
        approved: null,
        observedAt: 2,
        activeSegmentStartedAt: null,
        terminal: { pauseInfo: { type: "user" } },
        canResume: true,
    };
}

function workflowProgress() {
    return {
        records: [],
        oldestSeq: null,
        newestSeq: null,
        hasMoreOlder: false,
        hasMoreNewer: false,
        revision: 2,
    };
}

function attach(input, output) {
    let buffer = Buffer.alloc(0);
    const pending = new Map();
    const journal = new Map();

    function send(message) {
        const body = JSON.stringify(message);
        output.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
    }

    function request(method, params) {
        const id = nextRequestId++;
        send({ jsonrpc: "2.0", id, method, params });
        return new Promise((resolve) => pending.set(id, { resolve }));
    }

    async function handle(message) {
        if (message.method === undefined) {
            const waiter = pending.get(message.id);
            if (!waiter) return;
            pending.delete(message.id);
            waiter.resolve(message);
            return;
        }

        const previousRequest = lastRequest;
        if (message.method !== "test.inspect") {
            lastRequest = message;
            requests.push(message);
        }
        if (
            args.includes("--hang-after-connect") &&
            message.method !== "connect"
        ) {
            return;
        }
        if (
            args.includes("--hang-release-interest") &&
            message.method === "session.eventLog.releaseInterest"
        ) {
            return;
        }
        let result;
        switch (message.method) {
            case "connect":
                if (args.includes("--fail-connect") || message.params.token === "reject") {
                    send({
                        jsonrpc: "2.0",
                        id: message.id,
                        error: { code: -32000, message: "connect rejected" },
                    });
                    return;
                }
                result = { ok: true, protocolVersion: 3, version: "fake" };
                break;
            case "runtime.shutdown":
                if (shutdownPath !== null) {
                    writeFileSync(shutdownPath, "requested");
                }
                if (shutdownFsPath !== null) {
                    const response = await request("sessionFs.readFile", {
                        sessionId: "shutdown-provider",
                        path: "/during-shutdown",
                    });
                    writeFileSync(
                        shutdownFsPath,
                        response.result?.content ?? "missing"
                    );
                }
                if (args.includes("--hang-shutdown")) return;
                if (args.includes("--fail-shutdown")) {
                    send({
                        jsonrpc: "2.0",
                        id: message.id,
                        error: { code: -32000, message: "shutdown rejected" },
                    });
                    return;
                }
                result = null;
                break;
            case "plugins.builtin.set":
            case "session.detach":
            case "session.eventLog.releaseInterest":
                result = { success: true };
                break;
            case "session.eventLog.registerInterest":
                result = { handle: "interest-1" };
                break;
            case "sessionFs.setProvider":
                result = { success: true };
                break;
            case "models.list":
                result = {
                    models: [
                        {
                            id: "runtime-model",
                            name: "Runtime model",
                            capabilities: {},
                        },
                    ],
                };
                break;
            case "session.create":
            case "session.resume":
                if (
                    args.includes("--fail-session") ||
                    (args.includes("--fail-resume") &&
                        message.method === "session.resume")
                ) {
                    send({
                        jsonrpc: "2.0",
                        id: message.id,
                        error: { code: -32000, message: "session rejected" },
                    });
                    return;
                }
                if (
                    args.includes("--fail-options-update-on-resume") &&
                    message.method === "session.resume"
                ) {
                    failNextOptionsUpdate = true;
                }
                result = { sessionId: message.params.sessionId, capabilities: {} };
                break;
            case "session.send":
                result = { messageId: "message-1" };
                break;
            case "session.options.update":
                if (
                    args.includes("--fail-options-update") ||
                    failNextOptionsUpdate
                ) {
                    failNextOptionsUpdate = false;
                    send({
                        jsonrpc: "2.0",
                        id: message.id,
                        error: { code: -32000, message: "options rejected" },
                    });
                    return;
                }
                result = { success: true };
                break;
            case "session.workflow.run":
                result = args.includes("--workflow-pending")
                    ? { runId: "run-1", status: "pending" }
                    : {
                          runId: "run-1",
                          attempt: 1,
                          status: "completed",
                          result: null,
                      };
                break;
            case "session.workflow.resume":
                result = args.includes("--workflow-pending")
                    ? {
                          workflowName: "demo",
                          run: { runId: "run-1", status: "running" },
                      }
                    : {
                          workflowName: "demo",
                          run: {
                              runId: "run-1",
                              attempt: 2,
                              status: "error",
                              error: "limit reached",
                              failure: {
                                  type: "workflow_limit_reached",
                                  kind: "maxAiCredits",
                                  value: 2.5,
                                  suggestedValue: 4,
                                  runId: "run-1",
                              },
                          },
                      };
                break;
            case "session.workflow.getRun":
                result = args.includes("--workflow-pending")
                    ? { runId: "run-1", status: "completed", result: 42 }
                    : {
                          runId: "run-1",
                          status: "paused",
                          pauseInfo: { type: "checkpoint", key: "review" },
                      };
                break;
            case "session.workflow.listRuns":
                result = {
                    runs: [workflowSummary()],
                    oldestSeq: null,
                    newestSeq: null,
                    hasMoreNewer: false,
                    omittedOlder: 0,
                };
                break;
            case "session.workflow.getRunDetail":
                result = {
                    ...workflowSummary(),
                    phases: [],
                    agents: [],
                    progress: workflowProgress(),
                };
                break;
            case "session.workflow.getRunProgress":
                result = workflowProgress();
                break;
            case "session.workflow.pause":
                result = { runId: "run-1", status: "cancelled", reason: null };
                break;
            case "session.workflow.cancel":
                result = { runId: "run-1", status: "completed" };
                break;
            case "session.workflow.agent":
                if (args.includes("--exercise-workflow-abort")) {
                    if (workflowAbortSent) {
                        result = { result: "too late" };
                        break;
                    }
                    hungWorkflowAgentId = message.id;
                    markHungWorkflowAgentReady();
                    return;
                }
                if (args.includes("--exercise-workflow-agent-failure")) {
                    send({
                        jsonrpc: "2.0",
                        id: message.id,
                        error: { code: -32000, message: "agent failed" },
                    });
                    return;
                }
                result = { result: { answer: message.params.prompt } };
                break;
            case "session.workflow.journal.get":
                result = journal.has(message.params.key)
                    ? { hit: true, resultJson: journal.get(message.params.key) }
                    : { hit: false };
                break;
            case "session.workflow.journal.put":
                journal.set(message.params.key, message.params.resultJson);
                result = {};
                break;
            case "session.workflow.pauseAtCheckpoint":
                result = { action: "continue" };
                break;
            case "session.workflow.log":
                result = {};
                break;
            case "test.inspect":
                if (workflowExercise !== null) {
                    await workflowExercise;
                }
                await new Promise((resolve) => setImmediate(resolve));
                result = {
                    args,
                    env: observedEnvironment,
                    lastRequest: previousRequest,
                    requests,
                    activeConnections,
                    workflowResult,
                };
                break;
            case "test.fs":
                result = await request(message.params.method, message.params.params);
                break;
            default:
                send({
                    jsonrpc: "2.0",
                    id: message.id,
                    error: { code: -32601, message: `Unhandled method ${message.method}` },
                });
                return;
        }
        send({ jsonrpc: "2.0", id: message.id, result });
        if (
            (args.includes("--exercise-workflow") ||
                args.includes("--exercise-workflow-abort") ||
                args.includes("--exercise-workflow-agent-failure")) &&
            message.method === "session.resume" &&
            Array.isArray(message.params.workflows) &&
            message.params.workflows.length > 0 &&
            workflowExercise === null
        ) {
            const execute = request("workflow.execute", {
                sessionId: message.params.sessionId,
                name: message.params.workflows[0].name,
                runId: "reverse-run",
                executionToken: "attempt-1",
                args: { prompt: "nested work" },
            });
            if (args.includes("--exercise-workflow-abort")) {
                workflowExercise = (async () => {
                    await hungWorkflowAgentReady;
                    const staleAbort = await request("workflow.abort", {
                        sessionId: message.params.sessionId,
                        runId: "reverse-run",
                        executionToken: "stale-attempt",
                    });
                    workflowAbortSent = true;
                    const abort = await request("workflow.abort", {
                        sessionId: message.params.sessionId,
                        runId: "reverse-run",
                        executionToken: "attempt-1",
                    });
                    send({
                        jsonrpc: "2.0",
                        id: hungWorkflowAgentId,
                        result: { result: "too late" },
                    });
                    hungWorkflowAgentId = null;
                    workflowResult = { execute: await execute, staleAbort, abort };
                })();
            } else {
                workflowExercise = execute.then((response) => {
                    workflowResult = response;
                });
            }
        }
        if (
            args.includes("--exercise-workflow-invalid") &&
            message.method === "session.resume" &&
            workflowExercise === null
        ) {
            workflowExercise = (async () => {
                const valid = {
                    sessionId: message.params.sessionId,
                    name: message.params.workflows[0].name,
                    runId: "invalid-run",
                    executionToken: "attempt-1",
                    args: null,
                };
                const missingArgs = { ...valid };
                delete missingArgs.args;
                const malformed = [];
                for (const params of [
                    null,
                    missingArgs,
                    { ...valid, name: 42 },
                    { ...valid, executionToken: "" },
                    { ...valid, extra: true },
                ]) malformed.push(await request("workflow.execute", params));
                const invalidResult = await request("workflow.execute", valid);
                const invalidAbort = await request("workflow.abort", {
                    ...valid,
                    executionToken: null,
                });
                workflowResult = { malformed, invalidResult, invalidAbort };
            })();
        }
        if (
            args.includes("--exercise-workflow-generic") &&
            message.method === "session.resume" &&
            workflowExercise === null
        ) {
            workflowExercise = (async () => {
                const execute = await request("workflow.execute", {
                    sessionId: message.params.sessionId,
                    name: "generic",
                    runId: "generic-run",
                    executionToken: "generic-attempt",
                    args: null,
                });
                const abort = await request("workflow.abort", {
                    sessionId: message.params.sessionId,
                    runId: "generic-run",
                    executionToken: "generic-attempt",
                });
                workflowResult = { execute, abort };
            })();
        }
    }

    input.on("data", (chunk) => {
        buffer = Buffer.concat([buffer, chunk]);
        while (true) {
            const boundary = buffer.indexOf("\r\n\r\n");
            if (boundary < 0) return;
            const header = buffer.subarray(0, boundary).toString();
            const match = /content-length:\s*(\d+)/i.exec(header);
            if (!match) throw new Error("missing Content-Length");
            const length = Number(match[1]);
            const bodyStart = boundary + 4;
            if (buffer.length < bodyStart + length) return;
            const body = buffer.subarray(bodyStart, bodyStart + length).toString();
            buffer = buffer.subarray(bodyStart + length);
            void handle(JSON.parse(body));
        }
    });
}

const portIndex = args.indexOf("--port");
if (args.includes("--stdio")) {
    attach(process.stdin, process.stdout);
} else {
    if (args.includes("--no-listen")) {
        process.stdout.write("runtime did not announce a port\n");
        process.exit(0);
    }
    const requestedPort = portIndex >= 0 ? Number(args[portIndex + 1]) : 0;
    const server = net.createServer((socket) => {
        activeConnections += 1;
        socket.once("close", () => {
            activeConnections -= 1;
        });
        attach(socket, socket);
    });
    server.listen(requestedPort, "127.0.0.1", () => {
        const address = server.address();
        if (args.includes("--never-announce")) return;
        setTimeout(() => {
            process.stdout.write(
                `listening on port ${address.port + announcePortOffset}\n`
            );
        }, announceDelayMs);
    });
}
