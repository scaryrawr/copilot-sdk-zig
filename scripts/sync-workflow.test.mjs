import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
