import assert from "node:assert/strict";
import { schemaValidationShape } from "./source-contract.mjs";

export const autoTierIdentifierPattern = "^[^\\s\\u0000-\\u001F\\u007F-\\u009F]+$";
const presets = ["efficiency", "balance", "intelligence", "fast"];

export function verifyAutoTierSchema(schema) {
  const actual = schemaValidationShape(schema.definitions?.AutoTier);
  const expected = Object.hasOwn(actual ?? {}, "x-extensible-enum")
    ? {
        type: "string",
        minLength: 1,
        pattern: autoTierIdentifierPattern,
        "x-extensible-enum": presets,
      }
    : { type: "string", enum: presets };
  assert.deepEqual(actual, schemaValidationShape(expected), "AutoTier schema changed");
}
