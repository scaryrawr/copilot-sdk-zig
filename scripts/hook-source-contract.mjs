import assert from "node:assert/strict";
import ts from "typescript";
import {
  inheritedInterfacePropertySignatures,
  interfacePropertySignatures,
  requireExactPropertySignatures,
} from "./source-contract.mjs";

export function verifySubagentHooksSourceContract(typesSource) {
  requireExactPropertySignatures(
    inheritedInterfacePropertySignatures(typesSource, "SubagentStartHookInput", "BaseHookInput"),
    {
      transcriptPath: "required:string",
      agentName: "required:string",
      agentDisplayName: "optional:string",
      agentDescription: "optional:string",
    },
    "SubagentStartHookInput",
  );
  requireExactPropertySignatures(
    inheritedInterfacePropertySignatures(typesSource, "SubagentStopHookInput", "SubagentStartHookInput"),
    {
      agentId: "optional:string",
      agentType: "required:string",
      stopReason: 'required:"end_turn"',
      response: "required:string",
    },
    "SubagentStopHookInput",
  );
  requireExactPropertySignatures(
    interfacePropertySignatures(typesSource, "SubagentStartHookOutput"),
    { additionalContext: "optional:string" },
    "SubagentStartHookOutput",
  );
  const sourceFile = ts.createSourceFile(
    "types.ts", typesSource, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS,
  );
  assert.equal(sourceFile.parseDiagnostics.length, 0, "hook source has TypeScript parse errors");
  const declarations = sourceFile.statements.filter(
    (node) => ts.isTypeAliasDeclaration(node) && node.name.text === "SubagentStopHookOutput",
  );
  assert.equal(declarations.length, 1, "SubagentStopHookOutput must have exactly one declaration");
  const output = declarations[0].type;
  assert(
    ts.isUnionTypeNode(output) && output.types.length === 2 &&
      output.types.every(ts.isTypeLiteralNode),
    "SubagentStopHookOutput union changed",
  );
  const branches = output.types.map((branch) =>
    interfacePropertySignatures(`export interface Branch ${branch.getText(sourceFile)}`, "Branch")
  );
  const block = branches.find((branch) => branch.decision === 'required:"block"');
  const allow = branches.find((branch) => branch.decision === 'optional:"allow"');
  assert(block && allow, "SubagentStopHookOutput decisions changed");
  requireExactPropertySignatures(block, {
    decision: 'required:"block"',
    reason: "required:string",
    modifiedResponse: "optional:string",
  }, "SubagentStopHookOutput block");
  requireExactPropertySignatures(allow, {
    decision: 'optional:"allow"',
    reason: "optional:never",
    modifiedResponse: "optional:string",
  }, "SubagentStopHookOutput allow");
}
