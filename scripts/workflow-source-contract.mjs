import assert from "node:assert/strict";
import ts from "typescript";
import {
  interfacePropertySignatures,
  requireExactPropertySignatures,
  zigStructFields,
} from "./source-contract.mjs";

export function verifyWorkflowOptionsSourceContract(workflowSource, zigSource) {
  const sourceFile = ts.createSourceFile(
    "workflow.ts", workflowSource, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS,
  );
  assert.equal(sourceFile.parseDiagnostics.length, 0, "workflow source has TypeScript parse errors");
  const declarations = sourceFile.statements.filter(
    (node) => ts.isInterfaceDeclaration(node) && node.name.text === "WorkflowRunOptions",
  );
  assert.equal(declarations.length, 1, "WorkflowRunOptions must have exactly one declaration");
  const declaration = declarations[0];
  const parameter = declaration.typeParameters?.[0];
  assert(
    declaration.typeParameters?.length === 1 &&
      parameter.name.text === "TArgs" &&
      parameter.constraint?.getText(sourceFile) === "JsonValue" &&
      parameter.default?.getText(sourceFile) === "JsonValue",
    "WorkflowRunOptions type parameter changed",
  );
  const runDeclaration = ts.createPrinter({ removeComments: true }).printNode(
    ts.EmitHint.Unspecified,
    ts.factory.updateInterfaceDeclaration(
      declaration, declaration.modifiers, declaration.name, undefined,
      declaration.heritageClauses, declaration.members,
    ),
    sourceFile,
  );
  const resumeOptions = {
    limits: "optional:WorkflowLimitOverrides",
    notifyOnComplete: "optional:boolean",
    logPhaseNames: "optional:boolean",
  };
  requireExactPropertySignatures(
    interfacePropertySignatures(runDeclaration, "WorkflowRunOptions"),
    { args: "optional:TArgs", ...resumeOptions },
    "WorkflowRunOptions",
  );
  requireExactPropertySignatures(
    interfacePropertySignatures(workflowSource, "WorkflowResumeOptions"),
    resumeOptions,
    "WorkflowResumeOptions",
  );
  const zigResumeOptions = {
    limits: { type: "?WorkflowLimitOverrides", default: "null" },
    notify_on_complete: { type: "?bool", default: "null" },
    log_phase_names: { type: "?bool", default: "null" },
  };
  requireExactPropertySignatures(
    zigStructFields(zigSource, "WorkflowRunOptions"),
    { args: { type: "?JsonView", default: "null" }, ...zigResumeOptions },
    "Zig WorkflowRunOptions",
  );
  requireExactPropertySignatures(
    zigStructFields(zigSource, "WorkflowResumeOptions"),
    zigResumeOptions,
    "Zig WorkflowResumeOptions",
  );
}
