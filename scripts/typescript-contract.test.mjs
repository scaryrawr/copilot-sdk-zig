import assert from "node:assert/strict";
import test from "node:test";
import ts from "typescript";
import {
  eventTypeBranch,
  namedClassConstructor,
  requireCallbackReturnsCall,
  requireCallOutsideNestedFunctions,
  registeredStringCallbacks,
} from "./typescript-contract.mjs";

test("named class constructor ignores constructors on other classes", () => {
  const source = `
class Decoy {
  constructor(options: CopilotClientOptions = {}) {
    this.builtinPluginDirectories = [];
  }
}

export class CopilotClient {
  constructor(options: CopilotClientOptions = {}) {
    this.builtinPluginDirectories = [...options.builtinPluginDirectories];
  }
}
`;
  const constructor = namedClassConstructor(source, "CopilotClient");

  assert.match(
    constructor.node.getText(constructor.sourceFile),
    /\[\.\.\.options\.builtinPluginDirectories\]/,
  );
  assert.doesNotMatch(
    constructor.node.getText(constructor.sourceFile),
    /builtinPluginDirectories = \[\]/,
  );
});

test("named class constructor ignores nested and unexported namesakes", () => {
  const source = `
namespace Decoys {
  export class CopilotClient {
    constructor() {
      this.decoy = true;
    }
  }
}

class CopilotClient {
  constructor() {
    this.unexported = true;
  }
}

export class CopilotClient {
  constructor() {
    this.actual = true;
  }
}
`;
  const constructor = namedClassConstructor(source, "CopilotClient");

  assert.match(constructor.node.getText(constructor.sourceFile), /this\.actual/);
});

test("registered string callbacks require the exact registration API", () => {
  const sourceFile = ts.createSourceFile(
    "callbacks.ts",
    `
function attachConnectionHandlers() {
  unrelated("exitPlanMode.request", () => wrongHandler());
  decoy.onRequest("exitPlanMode.request", () => wrongHandler());
  function unreachable() {
    this.connection.onRequest("exitPlanMode.request", () => wrongHandler());
  }
  this.connection.onRequest(
    "exitPlanMode.request",
    async (params) => await this.handleExitPlanModeRequest(params)
  );
  this.connection.onRequest(
    "autoModeSwitch.request",
    async (params) => await this.handleAutoModeSwitchRequest(params)
  );
}
`,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS,
  );
  const functionNode = sourceFile.statements.find(ts.isFunctionDeclaration);
  const callbacks = registeredStringCallbacks(
    functionNode,
    sourceFile,
    "this.connection.onRequest",
    "direct callbacks",
  );

  assert.deepEqual([...callbacks.keys()].sort(), [
    "autoModeSwitch.request",
    "exitPlanMode.request",
  ]);
  assert.match(
    callbacks.get("exitPlanMode.request").getText(sourceFile),
    /handleExitPlanModeRequest/,
  );
  requireCallbackReturnsCall(
    callbacks.get("exitPlanMode.request"),
    sourceFile,
    "this.handleExitPlanModeRequest",
    "params",
    "exit-plan callback",
  );
});

test("registered callbacks reject shadowing and unrelated returned values", () => {
  const duplicateSource = ts.createSourceFile(
    "duplicates.ts",
    `
function attachConnectionHandlers() {
  this.connection.onRequest("exitPlanMode.request", async (params) =>
    await this.handleExitPlanModeRequest(params)
  );
  this.connection.onRequest("exitPlanMode.request", legacyHandler);
}
`,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS,
  );
  assert.throws(
    () =>
      registeredStringCallbacks(
        duplicateSource.statements.find(ts.isFunctionDeclaration),
        duplicateSource,
        "this.connection.onRequest",
        "direct callbacks",
      ),
    /registers exitPlanMode\.request more than once/,
  );

  const wrongReturnSource = ts.createSourceFile(
    "wrong-return.ts",
    `
const callback = async (params) => {
  this.handleExitPlanModeRequest(params);
  return wrongResult;
};
`,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS,
  );
  const declaration = wrongReturnSource.statements[0].declarationList.declarations[0];
  assert.throws(
    () =>
      requireCallbackReturnsCall(
        declaration.initializer,
        wrongReturnSource,
        "this.handleExitPlanModeRequest",
        "params",
        "exit-plan callback",
      ),
    /does not directly return/,
  );
});

test("event branch lookup binds the discriminator to its handler body", () => {
  const sourceFile = ts.createSourceFile(
    "events.ts",
    `
function dispatch(event) {
  if (event.type === "other") {
    this._handleElicitationRequest(decoy);
  } else if (event.type === "elicitation.requested") {
    this._handleExpectedRequest(event.data);
  }
}
`,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS,
  );
  const functionNode = sourceFile.statements.find(ts.isFunctionDeclaration);
  const branch = eventTypeBranch(
    functionNode,
    sourceFile,
    "elicitation.requested",
    "elicitation dispatch",
  );

  assert.match(branch.getText(sourceFile), /_handleExpectedRequest/);
  assert.doesNotMatch(branch.getText(sourceFile), /_handleElicitationRequest/);
});

test("event dispatch rejects compound guards and nested call decoys", () => {
  const compoundSource = ts.createSourceFile(
    "compound.ts",
    `
function dispatch(event) {
  if (event.type === "elicitation.requested" && enabled) {
    this._handleOtherRequest(event.data);
  } else if (event.type === "elicitation.requested") {
    this._handleElicitationRequest(event.data);
  }
}
`,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS,
  );
  assert.throws(
    () =>
      eventTypeBranch(
        compoundSource.statements.find(ts.isFunctionDeclaration),
        compoundSource,
        "elicitation.requested",
        "elicitation dispatch",
      ),
    /condition changed/,
  );

  const nestedSource = ts.createSourceFile(
    "nested.ts",
    `
function dispatch(event) {
  if (event.type === "elicitation.requested") {
    function dead() {
      this._handleElicitationRequest(event.data);
    }
    this._handleOtherRequest(event.data);
  }
}
`,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS,
  );
  const branch = eventTypeBranch(
    nestedSource.statements.find(ts.isFunctionDeclaration),
    nestedSource,
    "elicitation.requested",
    "elicitation dispatch",
  );
  assert.throws(
    () =>
      requireCallOutsideNestedFunctions(
        branch,
        nestedSource,
        "this._handleElicitationRequest",
        "elicitation dispatch",
      ),
    /call is missing/,
  );
});
