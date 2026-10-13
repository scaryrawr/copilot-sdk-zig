import assert from "node:assert/strict";
import test from "node:test";
import { verifyJoinSessionSourceContract } from "./join-source-contract.mjs";

function sources(ownerOnly = []) {
  const types = `
export interface SessionConfigBase {
  extensionSdkPath?: string;
  ${ownerOnly.map(([name, type]) => `${name}?: ${type};`).join("\n")}
}
`;
  const extension = `
export type JoinSessionConfig = Omit<ResumeSessionConfig,
  "onPermissionRequest" | "extensionSdkPath"
  ${ownerOnly.map(([name]) => `| "${name}"`).join(" ")}
> & {
  onPermissionRequest?: PermissionHandler;
  requestedEnvironmentVariables?: string[];
  workflows?: WorkflowHandle[];
};
export async function joinSession(config: JoinSessionConfig = {}) {
  const {
    extensionSdkPath: _stripped,
    ${ownerOnly.map(([name]) => `${name}: _stripped${name},`).join("\n")}
    workflows, requestedEnvironmentVariables, ...rest
  } = config as JoinSessionConfig & { extensionSdkPath?: string };
  return client.resumeSessionForExtension(sessionId, { ...rest });
}
`;
  return { types, extension };
}

test("join guards preserve historical and current owner-only exclusions", () => {
  for (const fields of [
    [],
    [["skillProvider", "SkillProvider"]],
    [["skillProvider", "SkillProvider"], ["imageGeneration", "ImageGenerationConfig"]],
  ]) {
    const { types, extension } = sources(fields);
    const shape = verifyJoinSessionSourceContract(types, extension);
    assert.deepEqual(shape.excluded, [
      "onPermissionRequest", "extensionSdkPath", ...fields.map(([name]) => name),
    ]);
  }
});

test("join guards reject missing exclusions, owner-only redeclarations, and missing stripping", () => {
  const { types, extension } = sources([
    ["skillProvider", "SkillProvider"], ["imageGeneration", "ImageGenerationConfig"],
  ]);
  for (const field of ["extensionSdkPath", "skillProvider", "imageGeneration"]) {
    assert.throws(() => verifyJoinSessionSourceContract(
      types, extension.replace(`| "${field}"`, ""),
    ), /exclusions changed/);
    assert.throws(() => verifyJoinSessionSourceContract(
      types, extension.replace("onPermissionRequest?:", `${field}?: unknown; onPermissionRequest?:`),
    ), /fields changed/);
    assert.throws(() => verifyJoinSessionSourceContract(
      types, extension.replace(new RegExp(`${field}: _stripped\\w*,`), ""),
    ), /must strip owner-only/);
    for (const access of [`config.${field}`, `config["${field}"]`]) {
      assert.throws(() => verifyJoinSessionSourceContract(
        types, extension.replace("{ ...rest }", `{ ...rest, ${field}: ${access} }`),
      ), /must not forward owner-only/);
    }
  }
  assert.throws(() => verifyJoinSessionSourceContract(
    types.replace("imageGeneration?: ImageGenerationConfig", "imageGeneration?: unknown"),
    extension,
  ), /SessionConfigBase.imageGeneration changed/);
  assert.throws(() => verifyJoinSessionSourceContract(
    types, extension.replace('"onPermissionRequest"', '"onPermissionRequest" | "tools"'),
  ), /exclusions changed/);
});
