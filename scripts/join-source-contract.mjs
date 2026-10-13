import assert from "node:assert/strict";
import ts from "typescript";
import {
  interfacePropertySignatures,
  omitIntersectionAlias,
  requireExactPropertySignatures,
} from "./source-contract.mjs";

const ownerOnlyFields = {
  extensionSdkPath: "optional:string",
  skillProvider: "optional:SkillProvider",
  imageGeneration: "optional:ImageGenerationConfig",
};

export function joinOwnerOnlyFields(typesSource) {
  const base = interfacePropertySignatures(typesSource, "SessionConfigBase");
  const fields = [];
  for (const [name, signature] of Object.entries(ownerOnlyFields)) {
    if (name === "extensionSdkPath" || Object.hasOwn(base, name)) {
      assert.equal(base[name], signature, `SessionConfigBase.${name} changed`);
      fields.push(name);
    }
  }
  return fields;
}

export function verifyJoinSessionSourceContract(typesSource, extensionSource) {
  const omitted = joinOwnerOnlyFields(typesSource);
  const shape = omitIntersectionAlias(extensionSource, "JoinSessionConfig");
  assert.equal(shape.base, "ResumeSessionConfig", "JoinSessionConfig base changed");
  assert.deepEqual(
    [...shape.excluded].sort(),
    ["onPermissionRequest", ...omitted].sort(),
    "JoinSessionConfig exclusions changed",
  );
  requireExactPropertySignatures(shape.properties, {
    onPermissionRequest: "optional:PermissionHandler",
    requestedEnvironmentVariables: "optional:string[]",
    workflows: "optional:WorkflowHandle[]",
  }, "JoinSessionConfig");

  const sourceFile = ts.createSourceFile(
    "extension.ts", extensionSource, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS,
  );
  assert.equal(sourceFile.parseDiagnostics.length, 0, "extension source has TypeScript parse errors");
  const functions = sourceFile.statements.filter(
    (node) => ts.isFunctionDeclaration(node) && node.name?.text === "joinSession",
  );
  assert.equal(functions.length, 1, "joinSession must have exactly one declaration");
  const bindings = [];
  function visit(node) {
    if (
      ts.isVariableDeclaration(node) && ts.isObjectBindingPattern(node.name) &&
      node.initializer?.getText(sourceFile).replace(/\s+/g, "").startsWith("configas")
    ) {
      bindings.push(node.name.elements);
    }
    ts.forEachChild(node, visit);
  }
  visit(functions[0].body);
  assert.equal(bindings.length, 1, "joinSession config destructuring changed");
  const strippedBindings = new Map();
  for (const field of omitted) {
    const binding = bindings[0].find((binding) => binding.propertyName?.getText(sourceFile) === field);
    assert(
      binding && ts.isIdentifier(binding.name),
      `joinSession must strip owner-only ${field}`,
    );
    strippedBindings.set(binding.name.text, binding.name);
  }
  function rejectOwnerOnlyForwarding(node) {
    if (
      ts.isIdentifier(node) && strippedBindings.has(node.text) &&
      strippedBindings.get(node.text) !== node
    ) {
      assert(
        ts.isVoidExpression(node.parent) &&
          node.parent.expression === node &&
          ts.isExpressionStatement(node.parent.parent),
        `joinSession must not reuse stripped owner-only ${node.text}`,
      );
    }
    if (
      ts.isSpreadAssignment(node) &&
      node.expression.getText(sourceFile) === "config"
    ) {
      assert.fail("joinSession must not spread unstripped config");
    }
    if (
      ts.isPropertyAccessExpression(node) &&
      node.expression.getText(sourceFile) === "config"
    ) {
      assert(!omitted.includes(node.name.text), `joinSession must not forward owner-only ${node.name.text}`);
    }
    if (
      ts.isElementAccessExpression(node) &&
      node.expression.getText(sourceFile) === "config" &&
      ts.isStringLiteralLike(node.argumentExpression)
    ) {
      assert(!omitted.includes(node.argumentExpression.text), `joinSession must not forward owner-only ${node.argumentExpression.text}`);
    }
    ts.forEachChild(node, rejectOwnerOnlyForwarding);
  }
  rejectOwnerOnlyForwarding(functions[0].body);
  return shape;
}
