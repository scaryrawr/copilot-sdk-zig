import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";

const workflow = readFileSync(
  new URL("../.github/workflows/sync-upstream.yml", import.meta.url),
  "utf8",
);
const setupStart = workflow.indexOf("          branch=sync/upstream\n");
const setupEnd = workflow.indexOf("          npm ci\n", setupStart);
const pushStart = workflow.indexOf(
  '          if [ "$remote_branch" = true ]; then\n',
  workflow.indexOf('          git commit -m "Sync Copilot SDK contracts"'),
);
const pushEnd = workflow.indexOf("          pr=$(gh pr list", pushStart);
assert(setupStart >= 0 && setupEnd > setupStart && pushStart >= 0 && pushEnd > pushStart);
const setup = workflow.slice(setupStart, setupEnd).replace(/^ {10}/gm, "");
const push = workflow.slice(pushStart, pushEnd).replace(/^ {10}/gm, "");
const stageStart = workflow.indexOf("          git add \\\n");
const stageEnd = workflow.indexOf("          if ! git diff --cached --quiet", stageStart);
assert(stageStart >= 0 && stageEnd > stageStart);
const stage = workflow.slice(stageStart, stageEnd).replace(/^ {10}/gm, "");
const validationStart = workflow.indexOf('          log_file="$RUNNER_TEMP/upstream-sync.log"\n');
const validationEnd = workflow.indexOf("          issue_title=", validationStart);
assert(validationStart >= 0 && validationEnd > validationStart && validationEnd < stageStart);
const validation = workflow.slice(validationStart, validationEnd).replace(/^ {10}/gm, "");

const validationCommands = [
  "npm run sync -- --if-published --public-sdk-commit test-commit",
  "npm test",
  "zig fmt --check build.zig src examples scripts/parity_census_runner.zig",
  "zig build test",
  "zig build",
];

const validationStubs = `
public_sdk_commit=test-commit
record() {
  printf '%s\\n' "$*" >> commands.log
  if [ "$*" = "$FAIL_COMMAND" ]; then
    echo "validation failed: $*"
    return 42
  fi
}
npm() { record npm "$@"; }
zig() { record zig "$@"; }
`;

function run(cwd, command, args, env = process.env) {
  return execFileSync(command, args, {
    cwd,
    env,
    encoding: "utf8",
    stdio: "pipe",
  }).trim();
}

function git(cwd, ...args) {
  return run(cwd, "git", args);
}

function fixture(t, { staleBranch = true } = {}) {
  const root = mkdtempSync(join(tmpdir(), "sync-workflow-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  git(root, "init", "--bare", "--initial-branch=main", "origin.git");
  git(root, "clone", "origin.git", "work");
  const work = join(root, "work");
  git(work, "config", "user.name", "Sync Test");
  git(work, "config", "user.email", "sync@example.invalid");
  mkdirSync(join(work, "vendor/copilot"), { recursive: true });
  const metadata = join(work, "vendor/copilot/upstream.json");
  writeFileSync(metadata, "base\n");
  git(work, "add", "vendor/copilot/upstream.json");
  git(work, "commit", "-m", "base");
  git(work, "push", "origin", "main");
  let stale;
  if (staleBranch) {
    git(work, "checkout", "-b", "sync/upstream");
    writeFileSync(metadata, "stale\n");
    git(work, "commit", "-am", "stale sync");
    git(work, "push", "origin", "sync/upstream");
    stale = git(work, "rev-parse", "HEAD");
    git(work, "checkout", "main");
  }
  writeFileSync(metadata, "main\n");
  git(work, "commit", "-am", "new main pin");
  git(work, "push", "origin", "main");
  return { root, work, stale, main: git(work, "rev-parse", "HEAD") };
}

test("installs the pinned Zig toolchain needed for generation and validation", () => {
  assert.match(workflow, /uses: mlugg\/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29 # v2\n\s+with:\n\s+version: 0\.16\.0/);
});

for (const failedCommand of [null, ...validationCommands]) {
  test(`sync validation ${failedCommand ? `stops on ${failedCommand}` : "runs every gate"}`, (t) => {
    const root = mkdtempSync(join(tmpdir(), "sync-validation-"));
    t.after(() => rmSync(root, { recursive: true, force: true }));
    const execute = () => run(root, "bash", ["-e", "-o", "pipefail", "-c",
      `${validationStubs}\n${validation}\nexit "$sync_status"`], {
      ...process.env,
      RUNNER_TEMP: root,
      FAIL_COMMAND: failedCommand ?? "",
    });
    if (failedCommand) {
      assert.throws(execute, (error) => {
        assert.equal(error.status, 42);
        assert.match(error.stdout.toString(), /validation failed:/);
        return true;
      });
      assert.match(readFileSync(join(root, "upstream-sync.log"), "utf8"), /validation failed:/);
    } else {
      execute();
    }
    const count = failedCommand ? validationCommands.indexOf(failedCommand) + 1 : validationCommands.length;
    assert.deepEqual(
      readFileSync(join(root, "commands.log"), "utf8").trim().split("\n"),
      validationCommands.slice(0, count),
    );
  });
}

test("regenerates a stale sync branch from main without merging conflicting pins", (t) => {
  const { work, stale, main } = fixture(t);
  run(work, "bash", ["-e", "-c", `${setup}
test "$(cat vendor/copilot/upstream.json)" = main
printf 'generated\\n' > vendor/copilot/upstream.json
git add vendor/copilot/upstream.json
git commit -m generated
${push}`]);
  const head = git(work, "rev-parse", "HEAD");
  assert.equal(git(work, "ls-remote", "origin", "refs/heads/sync/upstream").split("\t")[0], head);
  assert.equal(git(work, "merge-base", "main", "HEAD"), main);
  assert.equal(git(work, "show", "HEAD:vendor/copilot/upstream.json"), "generated");
  assert.throws(() => git(work, "merge-base", "--is-ancestor", stale, head));
});

test("creates a sync branch when none exists", (t) => {
  const { work, main } = fixture(t, { staleBranch: false });
  run(work, "bash", ["-e", "-c", `${setup}
printf 'generated\\n' > vendor/copilot/upstream.json
git add vendor/copilot/upstream.json
git commit -m generated
${push}`]);
  assert.equal(git(work, "merge-base", "main", "HEAD"), main);
  assert.equal(git(work, "ls-remote", "origin", "refs/heads/sync/upstream").split("\t")[0],
    git(work, "rev-parse", "HEAD"));
});

test("stages every generated synchronization artifact", (t) => {
  const { work } = fixture(t, { staleBranch: false });
  const outputs = [
    "vendor/copilot/upstream.json",
    "vendor/copilot/schemas/api.schema.json",
    "vendor/copilot/schemas/session-events.schema.json",
    "src/protocol_version.zig",
    "src/session_event_generated.zig",
    "sync/compatibility.json",
    "sync/extensibility-contract.json",
    "sync/public-rpc-surface.json",
    "sync/schema-snapshot.json",
    "sync/stable-parity-contract.json",
  ];
  for (const output of outputs) {
    const path = join(work, output);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, "generated\n");
  }
  run(work, "bash", ["-e", "-c", stage]);
  assert.deepEqual(git(work, "diff", "--cached", "--name-only").split("\n"), outputs.sort());
  assert.equal(git(work, "diff", "--name-only"), "");
});

test("refuses to overwrite a sync branch updated after fetch", (t) => {
  const { root, work } = fixture(t);
  git(root, "clone", "origin.git", "peer");
  const peer = join(root, "peer");
  git(peer, "config", "user.name", "Sync Test");
  git(peer, "config", "user.email", "sync@example.invalid");
  assert.throws(
    () => run(work, "bash", ["-e", "-c", `${setup}
git -C "$PEER" checkout -b sync/upstream origin/sync/upstream
printf 'peer\\n' > "$PEER/vendor/copilot/upstream.json"
git -C "$PEER" commit -am "concurrent update"
git -C "$PEER" push origin sync/upstream
printf 'generated\\n' > vendor/copilot/upstream.json
git add vendor/copilot/upstream.json
git commit -m generated
${push}`], { ...process.env, PEER: peer }),
    (error) => {
      assert.match(error.stderr.toString(), /stale info/);
      return true;
    },
  );
  assert.equal(git(work, "ls-remote", "origin", "refs/heads/sync/upstream").split("\t")[0],
    git(peer, "rev-parse", "HEAD"));
});
