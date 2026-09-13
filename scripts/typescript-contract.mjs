import assert from "node:assert/strict";
import ts from "typescript";

function parseTypeScript(source, owner) {
  const sourceFile = ts.createSourceFile(
    `${owner}.ts`,
    source,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS,
  );
  assert.equal(
    sourceFile.parseDiagnostics.length,
    0,
    `upstream ${owner} has TypeScript parse errors`,
  );
  return sourceFile;
}

function nodeName(node, sourceFile) {
  if (!node.name) return null;
  if (ts.isIdentifier(node.name) || ts.isStringLiteralLike(node.name)) {
    return node.name.text;
  }
  return node.name.getText(sourceFile);
}

export function namedClassConstructor(source, className, owner = className) {
  const sourceFile = parseTypeScript(source, owner);
  const classes = sourceFile.statements.filter(
    (node) =>
      ts.isClassDeclaration(node) &&
      nodeName(node, sourceFile) === className &&
      node.modifiers?.some(
        (modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword,
      ),
  );
  assert.equal(
    classes.length,
    1,
    `upstream ${owner} must declare exactly one exported top-level ${className} class`,
  );
  const classNode = classes[0];

  const constructors = classNode.members.filter(ts.isConstructorDeclaration);
  assert.equal(
    constructors.length,
    1,
    `upstream ${owner} must declare exactly one ${className} constructor`,
  );
  return { node: constructors[0], sourceFile };
}

export function registeredStringCallbacks(
  root,
  sourceFile,
  registrationCallee,
  owner,
) {
  const callbacks = new Map();
  function visit(node) {
    if (node !== root && ts.isFunctionLike(node)) return;
    if (
      ts.isCallExpression(node) &&
      node.expression.getText(sourceFile).replace(/\s+/g, "") ===
        registrationCallee
    ) {
      const [method, callback] = node.arguments;
      if (ts.isStringLiteralLike(method)) {
        assert(
          !callbacks.has(method.text),
          `upstream ${owner} registers ${method.text} more than once`,
        );
        assert(
          callback !== undefined,
          `upstream ${owner} registration ${method.text} has no callback`,
        );
        callbacks.set(method.text, callback);
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(root);
  return callbacks;
}

export function eventTypeBranch(root, sourceFile, eventType, owner) {
  const matches = [];
  function containsEventType(node) {
    let found = false;
    function inspect(candidate) {
      if (ts.isStringLiteralLike(candidate) && candidate.text === eventType) {
        found = true;
        return;
      }
      if (!found) ts.forEachChild(candidate, inspect);
    }
    inspect(node);
    return found;
  }
  function visit(node) {
    if (node !== root && ts.isFunctionLike(node)) return;
    if (ts.isIfStatement(node) && containsEventType(node.expression)) {
      const expression = node.expression.getText(sourceFile).replace(/\s+/g, "");
      assert(
        expression === `event.type==="${eventType}"` ||
          expression === `"${eventType}"===event.type`,
        `upstream ${owner} ${eventType} condition changed`,
      );
      matches.push(node.thenStatement);
    }
    ts.forEachChild(node, visit);
  }
  visit(root);
  assert.equal(
    matches.length,
    1,
    `upstream ${owner} must declare exactly one ${eventType} event branch`,
  );
  return matches[0];
}

function callExpression(node) {
  let expression = node;
  while (
    ts.isAwaitExpression(expression) ||
    ts.isParenthesizedExpression(expression)
  ) {
    expression = expression.expression;
  }
  return ts.isCallExpression(expression) ? expression : null;
}

export function requireCallbackReturnsCall(
  callback,
  sourceFile,
  callee,
  argument,
  owner,
) {
  assert(
    ts.isArrowFunction(callback) || ts.isFunctionExpression(callback),
    `upstream ${owner} callback is not a function`,
  );
  const returned =
    ts.isBlock(callback.body)
      ? callback.body.statements.length === 1 &&
        ts.isReturnStatement(callback.body.statements[0])
        ? callback.body.statements[0].expression
        : null
      : callback.body;
  assert(
    returned !== null && returned !== undefined,
    `upstream ${owner} callback does not directly return`,
  );
  const call = callExpression(returned);
  assert(call !== null, `upstream ${owner} callback does not return a call`);
  assert.equal(
    call.expression.getText(sourceFile).replace(/\s+/g, ""),
    callee,
    `upstream ${owner} callback target changed`,
  );
  assert.equal(
    call.arguments.length,
    1,
    `upstream ${owner} callback argument count changed`,
  );
  assert.equal(
    call.arguments[0].getText(sourceFile).replace(/\s+/g, ""),
    argument,
    `upstream ${owner} callback argument changed`,
  );
}

export function requireCallOutsideNestedFunctions(
  root,
  sourceFile,
  callee,
  owner,
) {
  let found = null;
  function visit(node) {
    if (node !== root && ts.isFunctionLike(node)) return;
    if (
      ts.isCallExpression(node) &&
      node.expression.getText(sourceFile).replace(/\s+/g, "") === callee
    ) {
      found = node;
      return;
    }
    if (!found) ts.forEachChild(node, visit);
  }
  visit(root);
  assert(found, `upstream ${owner} call is missing: ${callee}`);
  return found;
}
