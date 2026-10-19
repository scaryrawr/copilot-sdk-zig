import assert from "node:assert/strict";
import test from "node:test";
import { resolveCliPackageVersion } from "./upstream-cli-version.mjs";

test("uses the manifest CLI pin without requesting a removed lockfile", async () => {
  const version = await resolveCliPackageVersion(
    { copilotCliVersion: "1.0.100-1" },
    () => assert.fail("package-lock.json must not be fetched"),
  );
  assert.equal(version, "1.0.100-1");
});

test("fetches the lockfile only when the manifest has no CLI pin", async () => {
  for (const manifest of [{}, { copilotCliVersion: null }]) {
    let requests = 0;
    const version = await resolveCliPackageVersion(manifest, async () => {
      requests += 1;
      return { packages: { "node_modules/@github/copilot": { version: "1.0.97" } } };
    });
    assert.equal(version, "1.0.97");
    assert.equal(requests, 1);
  }
});

test("rejects invalid manifest pins without falling back to a different version", async () => {
  for (const version of ["", "^1.0.100", "latest", "1.0", 100, {}]) {
    await assert.rejects(
      resolveCliPackageVersion(
        { copilotCliVersion: version },
        () => assert.fail("an invalid manifest pin must not use the lockfile"),
      ),
      /no exact Copilot CLI version/,
    );
  }
});

test("rejects missing or non-exact lockfile versions", async () => {
  for (const lock of [
    {},
    { packages: {} },
    { packages: { "node_modules/@github/copilot": {} } },
    { packages: { "node_modules/@github/copilot": { version: "~1.0.97" } } },
  ]) {
    await assert.rejects(
      resolveCliPackageVersion({}, async () => lock),
      /no exact Copilot CLI version/,
    );
  }
});

test("propagates lockfile request failures when the fallback is required", async () => {
  const failure = new Error("request failed with 404: package-lock.json");
  await assert.rejects(
    resolveCliPackageVersion({}, async () => { throw failure; }),
    (error) => error === failure,
  );
});
