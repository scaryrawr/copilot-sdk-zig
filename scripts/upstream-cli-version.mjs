import assert from "node:assert/strict";

export async function resolveCliPackageVersion(packageManifest, fetchLock) {
  const version =
    packageManifest.copilotCliVersion ??
    (await fetchLock()).packages?.["node_modules/@github/copilot"]?.version;
  assert(
    typeof version === "string" && /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version),
    "upstream package manifest has no exact Copilot CLI version",
  );
  return version;
}
