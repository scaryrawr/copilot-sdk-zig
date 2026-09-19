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
let factoryExercise = null;
let factoryResult = null;
let hungFactoryAgentId = null;
let markHungFactoryAgentReady;
const hungFactoryAgentReady = new Promise((resolve) => {
    markHungFactoryAgentReady = resolve;
});
let factoryAbortSent = false;
let nextRequestId = 10_000;
let activeConnections = 0;
const requests = [];
let failNextOptionsUpdate = false;

function attach(input, output) {
    let buffer = Buffer.alloc(0);
    const pending = new Map();

    function send(message) {
        const body = JSON.stringify(message);
        output.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
    }

    function request(method, params) {
        const id = nextRequestId++;
        if (args.includes("--exercise-factory")) {
            console.error(`factory diagnostic: send ${method} ${id}`);
        }
        send({ jsonrpc: "2.0", id, method, params });
        return new Promise((resolve) => pending.set(id, { resolve }));
    }

    async function handle(message) {
        if (args.includes("--exercise-factory")) {
            console.error(
                `factory diagnostic: receive ${message.method ?? `response ${message.id}`}`
            );
        }
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
            case "session.factory.run":
                result = args.includes("--factory-pending")
                    ? { runId: "run-1", status: "pending" }
                    : {
                          runId: "run-1",
                          attempt: 1,
                          status: "completed",
                          result: null,
                      };
                break;
            case "session.factory.resume":
                result = args.includes("--factory-pending")
                    ? {
                          factoryName: "demo",
                          run: { runId: "run-1", status: "running" },
                      }
                    : {
                          factoryName: "demo",
                          run: {
                              runId: "run-1",
                              attempt: 2,
                              status: "error",
                              error: "limit reached",
                              failure: {
                                  type: "factory_limit_reached",
                                  kind: "maxAiCredits",
                                  value: 2.5,
                                  suggestedValue: 4,
                                  runId: "run-1",
                              },
                          },
                      };
                break;
            case "session.factory.getRun":
                result = args.includes("--factory-pending")
                    ? { runId: "run-1", status: "completed", result: 42 }
                    : {
                          runId: "run-1",
                          status: "paused",
                          pauseInfo: { type: "checkpoint", key: "review" },
                      };
                break;
            case "session.factory.listRuns":
                result = { runs: [] };
                break;
            case "session.factory.getRunDetail":
                result = {
                    run: { runId: "run-1" },
                    phases: [],
                    agents: [],
                    progress: [],
                };
                break;
            case "session.factory.getRunProgress":
                result = { records: [] };
                break;
            case "session.factory.pause":
                result = { runId: "run-1", status: "cancelled", reason: null };
                break;
            case "session.factory.cancel":
                result = { runId: "run-1", status: "completed" };
                break;
            case "session.factory.agent":
                if (args.includes("--exercise-factory-abort")) {
                    if (factoryAbortSent) {
                        result = { result: "too late" };
                        break;
                    }
                    hungFactoryAgentId = message.id;
                    markHungFactoryAgentReady();
                    return;
                }
                if (args.includes("--exercise-factory-agent-failure")) {
                    send({
                        jsonrpc: "2.0",
                        id: message.id,
                        error: { code: -32000, message: "agent failed" },
                    });
                    return;
                }
                result = { result: { answer: message.params.prompt } };
                break;
            case "session.factory.journal.get":
                result = { hit: false };
                break;
            case "session.factory.journal.put":
            case "session.factory.log":
                result = { success: true };
                break;
            case "test.inspect":
                if (factoryExercise !== null) {
                    await factoryExercise;
                }
                await new Promise((resolve) => setImmediate(resolve));
                result = {
                    args,
                    env: observedEnvironment,
                    lastRequest: previousRequest,
                    requests,
                    activeConnections,
                    factoryResult,
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
            (args.includes("--exercise-factory") ||
                args.includes("--exercise-factory-abort") ||
                args.includes("--exercise-factory-agent-failure")) &&
            message.method === "session.resume" &&
            Array.isArray(message.params.factories) &&
            message.params.factories.length > 0 &&
            factoryExercise === null
        ) {
            const execute = request("factory.execute", {
                sessionId: message.params.sessionId,
                name: message.params.factories[0].name,
                runId: "reverse-run",
                executionToken: "attempt-1",
                args: { prompt: "nested work" },
            });
            if (args.includes("--exercise-factory-abort")) {
                factoryExercise = (async () => {
                    await hungFactoryAgentReady;
                    factoryAbortSent = true;
                    const abort = await request("factory.abort", {
                        sessionId: message.params.sessionId,
                        runId: "reverse-run",
                        executionToken: "attempt-1",
                    });
                    send({
                        jsonrpc: "2.0",
                        id: hungFactoryAgentId,
                        result: { result: "too late" },
                    });
                    hungFactoryAgentId = null;
                    factoryResult = { execute: await execute, abort };
                })();
            } else {
                factoryExercise = execute.then((response) => {
                    factoryResult = response;
                });
            }
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
