import assert from "node:assert/strict";
import test from "node:test";
import { parseSyncArgs } from "./sync-args.mjs";

const checkedIn = "a".repeat(40);
const latestPublic = "b".repeat(40);
const protocolCommit = "c".repeat(40);

test("uses the checked-in public SDK authority by default", () => {
  assert.deepEqual(parseSyncArgs(["--check"], checkedIn), {
    check: true,
    explicitCommit: undefined,
    ifPublished: false,
    publicSdkCommit: checkedIn,
  });
});

test("allows the scheduled workflow to verify latest public main", () => {
  assert.deepEqual(
    parseSyncArgs(
      ["--if-published", "--public-sdk-commit", latestPublic],
      checkedIn,
    ),
    {
      check: false,
      explicitCommit: undefined,
      ifPublished: true,
      publicSdkCommit: latestPublic,
    },
  );
});

test("supports pinned regeneration with an explicit public authority", () => {
  assert.deepEqual(
    parseSyncArgs(
      [
        "--commit",
        protocolCommit,
        "--public-sdk-commit",
        latestPublic,
      ],
      checkedIn,
    ),
    {
      check: false,
      explicitCommit: protocolCommit,
      ifPublished: false,
      publicSdkCommit: latestPublic,
    },
  );
});

test("rejects ambiguous modes and abbreviated commits", () => {
  assert.throws(
    () => parseSyncArgs(["--check", "--if-published"], checkedIn),
    /mutually exclusive/,
  );
  assert.throws(
    () => parseSyncArgs(["--public-sdk-commit", "main"], checkedIn),
    /full lowercase Git commit SHA/,
  );
  assert.throws(
    () =>
      parseSyncArgs(
        [
          "--public-sdk-commit",
          latestPublic,
          "--public-sdk-commit",
          protocolCommit,
        ],
        checkedIn,
      ),
    /specified only once/,
  );
});
