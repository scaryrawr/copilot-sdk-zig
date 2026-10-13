import assert from "node:assert/strict";
import test from "node:test";
import { autoTierIdentifierPattern, verifyAutoTierSchema } from "./auto-tier-contract.mjs";

const extensible = {
  type: "string",
  minLength: 1,
  pattern: autoTierIdentifierPattern,
  "x-extensible-enum": ["efficiency", "balance", "intelligence", "fast"],
};

test("auto-tier schema preserves reviewed closed and extensible contracts", () => {
  verifyAutoTierSchema({ definitions: { AutoTier: extensible } });
  verifyAutoTierSchema({ definitions: {
    AutoTier: { type: "string", enum: ["fast", "balance", "efficiency", "intelligence"] },
  } });
});

test("auto-tier schema rejects suggestion, pattern, and validation drift", () => {
  for (const mutation of [
    { minLength: 0 },
    { pattern: ".*" },
    { "x-extensible-enum": ["balance"] },
    { enum: ["efficiency", "balance", "intelligence", "fast"] },
    { maxLength: 10 },
  ]) {
    assert.throws(() => verifyAutoTierSchema({
      definitions: { AutoTier: { ...extensible, ...mutation } },
    }), /AutoTier schema changed/);
  }
});
