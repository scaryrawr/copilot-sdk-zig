import { spawn } from "node:child_process";
import { join } from "node:path";

const sessionId = process.env.SESSION_ID;
if (!sessionId) {
    throw new Error("This wrapper must be launched as a Copilot CLI extension.");
}

const executable =
    process.env.COPILOT_SDK_ZIG_JOIN_SESSION_BIN ??
    join(process.cwd(), "examples", "join-session", "zig-out", "bin", "join-session");

const child = spawn(executable, ["--session-id", sessionId], {
    env: process.env,
    stdio: "inherit",
});

await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", (code, signal) => {
        if (signal || code !== 0) {
            reject(new Error(`join-session exited with ${signal ?? code}`));
        } else {
            resolve();
        }
    });
});
