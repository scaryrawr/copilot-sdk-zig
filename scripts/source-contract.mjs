import assert from "node:assert/strict";

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function previousCodeIndex(source, classes, index) {
  let previous = index - 1;
  while (
    previous >= 0 &&
    (classes[previous] !== 0 || /\s/.test(source[previous]))
  ) {
    previous -= 1;
  }
  return previous;
}

function followsControlHeader(source, classes, closeIndex) {
  let depth = 1;
  let index = closeIndex - 1;
  for (; index >= 0; index -= 1) {
    if (classes[index] !== 0) continue;
    if (source[index] === ")") depth += 1;
    if (source[index] === "(") {
      depth -= 1;
      if (depth === 0) break;
    }
  }
  if (depth !== 0) return false;

  const previous = previousCodeIndex(source, classes, index);
  if (previous < 0 || !/[A-Za-z_$]/.test(source[previous])) return false;
  let start = previous;
  while (start > 0 && /[\w$]/.test(source[start - 1])) start -= 1;
  return new Set(["catch", "for", "if", "switch", "while", "with"]).has(
    source.slice(start, previous + 1),
  );
}

function canStartRegex(source, classes, index) {
  const previous = previousCodeIndex(source, classes, index);
  if (previous < 0) return true;
  if ("([{:;,=!?&|+-*%^~<>".includes(source[previous])) return true;
  if (
    source[previous] === ")" &&
    followsControlHeader(source, classes, previous)
  ) {
    return true;
  }
  if (!/[A-Za-z_$]/.test(source[previous])) return false;

  let start = previous;
  while (start > 0 && /[\w$]/.test(source[start - 1])) start -= 1;
  return new Set([
    "await",
    "case",
    "delete",
    "do",
    "else",
    "in",
    "instanceof",
    "new",
    "of",
    "return",
    "throw",
    "typeof",
    "void",
    "yield",
  ]).has(source.slice(start, previous + 1));
}

function regexEnd(source, start) {
  let inCharacterClass = false;
  for (let index = start + 1; index < source.length; index += 1) {
    const character = source[index];
    if (character === "\n" || character === "\r") return -1;
    if (character === "\\") {
      index += 1;
      continue;
    }
    if (character === "[") {
      inCharacterClass = true;
      continue;
    }
    if (character === "]") {
      inCharacterClass = false;
      continue;
    }
    if (character === "/" && !inCharacterClass) {
      while (/[A-Za-z]/.test(source[index + 1] ?? "")) index += 1;
      return index;
    }
  }
  return -1;
}

function lexicalClasses(source) {
  const classes = new Uint8Array(source.length);
  let quote = null;

  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1];

    if (quote !== null) {
      classes[index] = 1;
      if (character === "\\") {
        index += 1;
        if (index < source.length) classes[index] = 1;
      } else if (character === quote) {
        quote = null;
      }
      continue;
    }

    if (character === "/" && next === "/") {
      classes[index] = 2;
      classes[index + 1] = 2;
      index += 2;
      while (index < source.length && source[index] !== "\n") {
        classes[index] = 2;
        index += 1;
      }
      index -= 1;
      continue;
    }

    if (character === "/" && next === "*") {
      classes[index] = 2;
      classes[index + 1] = 2;
      const commentEnd = source.indexOf("*/", index + 2);
      assert(commentEnd >= 0, "source has an unterminated comment");
      classes.fill(2, index, commentEnd + 2);
      index = commentEnd + 1;
      continue;
    }

    if (character === "/" && canStartRegex(source, classes, index)) {
      const end = regexEnd(source, index);
      if (end >= 0) {
        classes.fill(3, index, end + 1);
        index = end;
        continue;
      }
    }

    if (character === "'" || character === '"' || character === "`") {
      quote = character;
      classes[index] = 1;
    }
  }

  assert(quote === null, "source has an unterminated string");
  return classes;
}

function codeOnly(source) {
  const classes = lexicalClasses(source);
  let result = "";
  for (let index = 0; index < source.length; index += 1) {
    result += classes[index] === 0 || source[index] === "\n"
      ? source[index]
      : " ";
  }
  return result;
}

function withoutZigMultilineStrings(source) {
  return source.replace(
    /^[ \t]*\\\\.*$/gm,
    (line) => " ".repeat(line.length),
  );
}

function sourceFragmentIndex(source, fragment, start = 0) {
  const sourceClasses = lexicalClasses(source);
  const fragmentClasses = lexicalClasses(fragment);
  let index = source.indexOf(fragment, start);
  while (index >= 0) {
    let matches = true;
    for (let offset = 0; offset < fragment.length; offset += 1) {
      if (sourceClasses[index + offset] !== fragmentClasses[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return index;
    index = source.indexOf(fragment, index + 1);
  }
  return -1;
}

function scanDelimited(
  source,
  openIndex,
  separator,
  owner,
  { angles = false } = {},
) {
  const closingDelimiter = {
    "(": ")",
    "[": "]",
    "{": "}",
  };
  if (angles) closingDelimiter["<"] = ">";
  const openingDelimiter = new Set(Object.keys(closingDelimiter));
  const closingDelimiters = new Set(Object.values(closingDelimiter));
  const stack = [closingDelimiter[source[openIndex]]];
  assert(stack[0], `${owner} declaration has no opening delimiter`);

  const segments = [];
  let segment = "";
  let quote = null;

  for (let index = openIndex + 1; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1];

    if (quote !== null) {
      segment += character;
      if (character === "\\") {
        index += 1;
        if (index < source.length) segment += source[index];
      } else if (character === quote) {
        quote = null;
      }
      continue;
    }

    if (character === "/" && next === "/") {
      index += 2;
      while (index < source.length && source[index] !== "\n") index += 1;
      segment += "\n";
      continue;
    }

    if (character === "/" && next === "*") {
      const commentEnd = source.indexOf("*/", index + 2);
      assert(commentEnd >= 0, `${owner} declaration has an unterminated comment`);
      index = commentEnd + 1;
      segment += " ";
      continue;
    }

    if (character === "'" || character === '"' || character === "`") {
      quote = character;
      segment += character;
      continue;
    }

    if (openingDelimiter.has(character)) {
      stack.push(closingDelimiter[character]);
      segment += character;
      continue;
    }

    if (angles && character === ">" && source[index - 1] === "=") {
      segment += character;
      continue;
    }

    if (closingDelimiters.has(character)) {
      assert(
        stack.at(-1) === character,
        `${owner} declaration has mismatched delimiters`,
      );
      stack.pop();
      if (stack.length === 0) {
        if (segment.trim() !== "") segments.push(segment);
        return { segments, endIndex: index };
      }
      segment += character;
      continue;
    }

    if (character === separator && stack.length === 1) {
      if (segment.trim() !== "") segments.push(segment);
      segment = "";
      continue;
    }

    segment += character;
  }

  assert(quote === null, `${owner} declaration has an unterminated string`);
  assert.fail(`${owner} declaration has no matching ${stack[0]}`);
}

function skipTrivia(source, start) {
  let index = start;
  while (index < source.length) {
    if (/\s/.test(source[index])) {
      index += 1;
      continue;
    }
    if (source[index] === "/" && source[index + 1] === "/") {
      index += 2;
      while (index < source.length && source[index] !== "\n") index += 1;
      continue;
    }
    if (source[index] === "/" && source[index + 1] === "*") {
      const commentEnd = source.indexOf("*/", index + 2);
      assert(commentEnd >= 0, "declaration has an unterminated comment");
      index = commentEnd + 2;
      continue;
    }
    break;
  }
  return index;
}

function exportedInterfaceDeclaration(source, name) {
  const code = codeOnly(source);
  const declarations = [
    ...code.matchAll(
      new RegExp(
        `\\bexport\\s+(?:declare\\s+)?interface\\s+${escapeRegex(name)}\\b`,
        "g",
      ),
    ),
  ];
  assert.equal(
    declarations.length,
    1,
    `upstream ${name} must have exactly one exported interface declaration`,
  );

  const declaration = declarations[0];
  let index = skipTrivia(
    code,
    declaration.index + declaration[0].length,
  );
  let base = null;
  if (/^extends\b/.test(code.slice(index))) {
    index = skipTrivia(code, index + "extends".length);
    const baseMatch = /^[A-Za-z_$][\w$]*/.exec(code.slice(index));
    assert(baseMatch, `upstream ${name} must extend one simple base`);
    base = baseMatch[0];
    index = skipTrivia(code, index + base.length);
  }
  assert(
    code[index] === "{",
    `upstream ${name} must extend one simple base`,
  );
  return { base, openIndex: index };
}

function propertySignatures(declarations, owner) {
  const properties = {};
  for (const declaration of declarations) {
    const normalized = declaration.trim();
    assert(normalized !== "", `${owner} has an empty property declaration`);
    const match = normalized.match(
      /^(?:readonly\s+)?([A-Za-z_$][\w$]*)(\?)?\s*:\s*([\s\S]+?)\s*$/,
    );
    assert(match, `${owner} has an unsupported property declaration`);
    assert(
      !Object.hasOwn(properties, match[1]),
      `${owner} has duplicate property ${match[1]}`,
    );
    properties[match[1]] =
      `${match[2] === "?" ? "optional" : "required"}:${normalizeType(match[3], owner)}`;
  }
  return properties;
}

function methodSignature(declaration, owner) {
  const match = declaration.match(
    /^([A-Za-z_$][\w$]*)(\?)?\s*\(/,
  );
  if (!match) return null;

  const openIndex = match[0].lastIndexOf("(");
  const parameters = scanDelimited(
    declaration,
    openIndex,
    ",",
    owner,
    { angles: true },
  );
  const normalizedParameters = parameters.segments.map((parameter) => {
    const parameterMatch = parameter.trim().match(
      /^([A-Za-z_$][\w$]*)(\?)?\s*:\s*([\s\S]+)$/,
    );
    assert(parameterMatch, `${owner} has an unsupported parameter declaration`);
    return `${parameterMatch[1]}${parameterMatch[2] ?? ""}:${normalizeType(
      parameterMatch[3],
      owner,
    )}`;
  });

  let index = skipTrivia(declaration, parameters.endIndex + 1);
  assert(declaration[index] === ":", `${owner} method has no return type`);
  index = skipTrivia(declaration, index + 1);
  const returnType = declaration.slice(index);
  assert(returnType.trim() !== "", `${owner} method has no return type`);

  return {
    name: match[1],
    signature:
      `${match[2] === "?" ? "optional" : "required"}:` +
      `(${normalizedParameters.join(",")})=>${normalizeType(returnType, owner)}`,
  };
}

function normalizeType(source, owner) {
  const tokens = [];
  let index = 0;
  while (index < source.length) {
    index = skipTrivia(source, index);
    if (index >= source.length) break;
    const start = index;
    const character = source[index];
    if (/[A-Za-z0-9_$@]/.test(character)) {
      index += 1;
      while (index < source.length && /[A-Za-z0-9_$@]/.test(source[index])) {
        index += 1;
      }
      tokens.push({ kind: "word", value: source.slice(start, index) });
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      const quote = character;
      index += 1;
      while (index < source.length && source[index] !== quote) {
        if (source[index] === "\\") index += 1;
        index += 1;
      }
      assert(index < source.length, `${owner} has an unterminated string`);
      index += 1;
      tokens.push({ kind: "literal", value: source.slice(start, index) });
      continue;
    }
    tokens.push({ kind: "punctuation", value: character });
    index += 1;
  }
  assert(tokens.length > 0, `${owner} has no declared type`);
  return tokens
    .map((token, tokenIndex) => {
      const previous = tokens[tokenIndex - 1];
      const separator =
        token.kind === "word" && previous?.kind === "word" ? " " : "";
      return `${separator}${token.value}`;
    })
    .join("");
}

export function interfacePropertySignatures(source, name) {
  const declaration = exportedInterfaceDeclaration(source, name);
  assert(
    declaration.base === null,
    `upstream ${name} must not use inheritance`,
  );
  const declarations = scanDelimited(
    source,
    declaration.openIndex,
    ";",
    `upstream ${name}`,
  ).segments;
  return propertySignatures(declarations, `upstream ${name}`);
}

export function interfaceMemberSignatures(source, name) {
  const declaration = exportedInterfaceDeclaration(source, name);
  assert(
    declaration.base === null,
    `upstream ${name} must not use inheritance`,
  );
  const declarations = scanDelimited(
    source,
    declaration.openIndex,
    ";",
    `upstream ${name}`,
  ).segments;
  const methods = {};
  const propertyDeclarations = [];

  for (const declaration of declarations) {
    const normalized = declaration.trim();
    assert(normalized !== "", `upstream ${name} has an empty declaration`);
    const method = methodSignature(normalized, `upstream ${name}`);
    if (method === null) {
      propertyDeclarations.push(declaration);
      continue;
    }
    assert(
      !Object.hasOwn(methods, method.name),
      `upstream ${name} has duplicate method ${method.name}`,
    );
    methods[method.name] = method.signature;
  }

  return {
    methods,
    properties: propertySignatures(propertyDeclarations, `upstream ${name}`),
  };
}

export function interfaceBase(source, name) {
  const declaration = exportedInterfaceDeclaration(source, name);
  assert(declaration.base !== null, `upstream ${name} inheritance changed`);
  return declaration.base;
}

export function inheritedInterfacePropertySignatures(
  source,
  name,
  expectedBase,
) {
  const declaration = exportedInterfaceDeclaration(source, name);
  assert(
    declaration.base === expectedBase,
    `upstream ${name} must extend exactly ${expectedBase}`,
  );
  const declarations = scanDelimited(
    source,
    declaration.openIndex,
    ";",
    `upstream ${name}`,
  ).segments;
  return propertySignatures(declarations, `upstream ${name}`);
}

export function exportedStringUnionValues(source, name) {
  const code = codeOnly(source);
  const declarations = [
    ...code.matchAll(
      new RegExp(
        `\\bexport\\s+type\\s+${escapeRegex(name)}\\b`,
        "g",
      ),
    ),
  ];
  assert.equal(
    declarations.length,
    1,
    `upstream ${name} must have exactly one exported type alias declaration`,
  );

  const declaration = declarations[0];
  let index = skipTrivia(
    code,
    declaration.index + declaration[0].length,
  );
  assert(code[index] === "=", `upstream ${name} declaration changed`);
  index = skipTrivia(source, index + 1);
  const endIndex = code.indexOf(";", index);
  assert(endIndex >= 0, `upstream ${name} declaration has no semicolon`);

  const members = scanDelimited(
    `(${source.slice(index, endIndex)})`,
    0,
    "|",
    `upstream ${name}`,
  ).segments;
  assert(members.length > 0, `upstream ${name} must have at least one value`);

  const values = members.map((member) => {
    const literal = member.trim().match(
      /^(?:"([^"\\]*)"|'([^'\\]*)')$/,
    );
    assert(literal, `upstream ${name} members must be string literals`);
    return literal[1] ?? literal[2];
  });
  for (const value of values) {
    assert(
      values.indexOf(value) === values.lastIndexOf(value),
      `upstream ${name} has duplicate value ${value}`,
    );
  }
  return values;
}

export function omitIntersectionAlias(source, name) {
  const declaration = new RegExp(
    `\\bexport\\s+type\\s+${escapeRegex(name)}\\s*=`,
  ).exec(codeOnly(source));
  assert(declaration, `upstream ${name} declaration changed`);

  let index = skipTrivia(source, declaration.index + declaration[0].length);
  assert(source.slice(index, index + 4) === "Omit", `${name} must use Omit`);
  index = skipTrivia(source, index + 4);
  assert(source[index] === "<", `${name} must use Omit type arguments`);
  const omit = scanDelimited(source, index, ",", name, { angles: true });
  assert(omit.segments.length === 2, `${name} must have two Omit type arguments`);

  const base = omit.segments[0].trim();
  assert(
    /^[A-Za-z_$][\w$]*$/.test(base),
    `${name} has an unsupported Omit base`,
  );

  const excluded = scanDelimited(
    `(${omit.segments[1]})`,
    0,
    "|",
    `${name} exclusions`,
  ).segments.map((value) => {
    const literal = value.trim().match(/^(['"])([^'"\\]*)\1$/);
    assert(literal, `${name} exclusions must be string literals`);
    return literal[2];
  });
  assert(excluded.length > 0, `${name} must exclude at least one property`);
  assert(
    new Set(excluded).size === excluded.length,
    `${name} has duplicate exclusions`,
  );

  index = skipTrivia(source, omit.endIndex + 1);
  assert(source[index] === "&", `${name} must intersect one property object`);
  index = skipTrivia(source, index + 1);
  assert(source[index] === "{", `${name} must intersect one property object`);
  const intersection = scanDelimited(source, index, ";", name);
  const properties = propertySignatures(intersection.segments, name);

  index = skipTrivia(source, intersection.endIndex + 1);
  assert(source[index] === ";", `${name} has trailing syntax`);

  return { base, excluded, properties };
}

export function plainOmitAlias(source, name) {
  const code = codeOnly(source);
  const declarations = [
    ...code.matchAll(
      new RegExp(
        `\\bexport\\s+type\\s+${escapeRegex(name)}\\s*=`,
        "g",
      ),
    ),
  ];
  assert.equal(
    declarations.length,
    1,
    `upstream ${name} must have exactly one exported type alias declaration`,
  );

  const declaration = declarations[0];
  let index = skipTrivia(
    source,
    declaration.index + declaration[0].length,
  );
  assert(source.slice(index, index + 4) === "Omit", `${name} must use Omit`);
  index = skipTrivia(source, index + 4);
  assert(source[index] === "<", `${name} must use Omit type arguments`);
  const omit = scanDelimited(source, index, ",", name, { angles: true });
  assert(omit.segments.length === 2, `${name} must have two Omit type arguments`);

  const base = omit.segments[0].trim();
  assert(
    /^[A-Za-z_$][\w$]*$/.test(base),
    `${name} has an unsupported Omit base`,
  );

  const excluded = scanDelimited(
    `(${omit.segments[1]})`,
    0,
    "|",
    `${name} exclusions`,
  ).segments.map((value) => {
    const literal = value.trim().match(/^(['"])([^'"\\]*)\1$/);
    assert(literal, `${name} exclusions must be string literals`);
    return literal[2];
  });
  assert(excluded.length > 0, `${name} must exclude at least one property`);
  assert(
    new Set(excluded).size === excluded.length,
    `${name} has duplicate exclusions`,
  );

  index = skipTrivia(source, omit.endIndex + 1);
  assert(source[index] === ";", `${name} has trailing syntax`);
  return { base, excluded };
}

function topLevelCharacter(source, target, owner) {
  const closingDelimiter = {
    "(": ")",
    "[": "]",
    "{": "}",
  };
  const openingDelimiter = new Set(Object.keys(closingDelimiter));
  const stack = [];
  let quote = null;

  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1];
    if (quote !== null) {
      if (character === "\\") {
        index += 1;
      } else if (character === quote) {
        quote = null;
      }
      continue;
    }
    if (character === "/" && next === "/") {
      index += 2;
      while (index < source.length && source[index] !== "\n") index += 1;
      continue;
    }
    if (character === "/" && next === "*") {
      const commentEnd = source.indexOf("*/", index + 2);
      assert(commentEnd >= 0, `${owner} has an unterminated comment`);
      index = commentEnd + 1;
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      quote = character;
      continue;
    }
    if (openingDelimiter.has(character)) {
      stack.push(closingDelimiter[character]);
      continue;
    }
    if (character === ")" || character === "]" || character === "}") {
      assert(stack.at(-1) === character, `${owner} has mismatched delimiters`);
      stack.pop();
      continue;
    }
    if (character === target && stack.length === 0) return index;
  }

  assert(quote === null, `${owner} has an unterminated string`);
  assert(stack.length === 0, `${owner} has unmatched delimiters`);
  return -1;
}

function topLevelDeclarations(code, declaration) {
  const matches = [];
  let braceDepth = 0;
  let cursor = 0;

  for (const match of code.matchAll(declaration)) {
    while (cursor < match.index) {
      if (code[cursor] === "{") braceDepth += 1;
      if (code[cursor] === "}") braceDepth -= 1;
      cursor += 1;
    }
    if (braceDepth === 0) matches.push(match);
  }
  return matches;
}

export function zigStructFields(source, name, { allowMethods = false } = {}) {
  const zigSource = withoutZigMultilineStrings(source);
  const declarations = topLevelDeclarations(
    codeOnly(zigSource),
    new RegExp(
      `\\bpub\\s+const\\s+${escapeRegex(name)}\\s*=\\s*struct\\s*\\{`,
      "g",
    ),
  );
  assert(declarations.length > 0, `Zig ${name} declaration changed`);
  assert.equal(
    declarations.length,
    1,
    `Zig ${name} must have exactly one applicable top-level declaration`,
  );
  const declaration = declarations[0];
  const openIndex = declaration.index + declaration[0].lastIndexOf("{");
  const struct = scanDelimited(zigSource, openIndex, ",", `Zig ${name}`);
  const fields = {};

  for (const rawField of struct.segments) {
    const field = rawField.trim();
    assert(field !== "", `Zig ${name} has an empty field`);
    if (allowMethods && field.startsWith("pub fn ")) break;
    const colon = topLevelCharacter(field, ":", `Zig ${name}`);
    assert(colon >= 0, `Zig ${name} has an unsupported field declaration`);
    const fieldName = field.slice(0, colon).trim();
    assert(
      /^[A-Za-z_][A-Za-z0-9_]*$/.test(fieldName),
      `Zig ${name} has an unsupported field name`,
    );
    assert(
      !Object.hasOwn(fields, fieldName),
      `Zig ${name} has duplicate field ${fieldName}`,
    );
    const declarationType = field.slice(colon + 1);
    const defaultIndex = topLevelCharacter(
      declarationType,
      "=",
      `Zig ${name}.${fieldName}`,
    );
    const defaultSource = defaultIndex === -1
      ? null
      : declarationType.slice(defaultIndex + 1);
    if (defaultSource !== null) {
      assert(defaultSource.trim() !== "", `Zig ${name}.${fieldName} has an empty default`);
    }
    const type = defaultIndex === -1
      ? declarationType
      : declarationType.slice(0, defaultIndex);
    fields[fieldName] = {
      type: normalizeType(type, `Zig ${name}.${fieldName}`),
      default: defaultSource === null
        ? null
        : normalizeType(defaultSource, `Zig ${name}.${fieldName} default`),
    };
  }

  let index = skipTrivia(zigSource, struct.endIndex + 1);
  assert(zigSource[index] === ";", `Zig ${name} has trailing syntax`);
  return fields;
}

export function zigEnumValues(
  source,
  name,
  { visibility = "public" } = {},
) {
  assert(
    visibility === "public" || visibility === "optional",
    `unsupported Zig enum visibility: ${visibility}`,
  );
  const prefix = visibility === "public" ? "pub\\s+const" : "(?:pub\\s+)?const";
  const zigSource = withoutZigMultilineStrings(source);
  const declarations = topLevelDeclarations(
    codeOnly(zigSource),
    new RegExp(
      `\\b${prefix}\\s+${escapeRegex(name)}\\s*=\\s*enum\\s*\\{`,
      "g",
    ),
  );
  assert(declarations.length > 0, `Zig ${name} declaration changed`);
  assert.equal(
    declarations.length,
    1,
    `Zig ${name} must have exactly one applicable top-level declaration`,
  );
  const match = declarations[0];
  const openIndex = match.index + match[0].lastIndexOf("{");
  const values = scanDelimited(
    zigSource,
    openIndex,
    ",",
    `Zig ${name}`,
  ).segments;
  return values.map((value) => {
    const normalized = value.trim();
    assert(/^\w+$/.test(normalized), `Zig ${name} declaration changed`);
    return normalized;
  });
}

export function sourceSection(source, startMarker, endMarker, owner) {
  const start = sourceFragmentIndex(source, startMarker);
  assert(start >= 0, `upstream ${owner} declaration is missing: ${startMarker}`);
  const end = sourceFragmentIndex(
    source,
    endMarker,
    start + startMarker.length,
  );
  assert(end >= 0, `upstream ${owner} declaration has no boundary: ${endMarker}`);
  return source.slice(start, end);
}

export function requireSourceFragments(source, fragments, owner) {
  for (const fragment of fragments) {
    assert(
      sourceFragmentIndex(source, fragment) >= 0,
      `upstream ${owner} declaration is missing: ${fragment}`,
    );
  }
}

function identifierAt(source, start) {
  const match = /^[A-Za-z_$][\w$]*/.exec(source.slice(start));
  if (!match) return null;
  return { value: match[0], endIndex: start + match[0].length };
}

function mentionsImportName(source, expected) {
  const code = codeOnly(source);
  return [expected.imported, expected.local].some((name) =>
    new RegExp(`\\b${escapeRegex(name)}\\b`).test(code)
  );
}

function assertUnsupportedImportIsIrrelevant(source, expected, owner) {
  assert(
    !mentionsImportName(source, expected),
    `upstream ${owner} uses unsupported import syntax`,
  );
}

function plainModuleSpecifier(source, start, owner) {
  const quote = source[start];
  assert(
    quote === "'" || quote === '"',
    `upstream ${owner} uses unsupported import syntax`,
  );

  let value = "";
  for (let index = start + 1; index < source.length; index += 1) {
    const character = source[index];
    assert(
      character !== "\\" && character !== "\n" && character !== "\r",
      `upstream ${owner} uses unsupported import syntax`,
    );
    if (character === quote) {
      return { value, endIndex: index };
    }
    value += character;
  }

  assert.fail(`upstream ${owner} uses unsupported import syntax`);
}

function assertImportEnd(source, moduleEndIndex, owner) {
  const nextIndex = skipTrivia(source, moduleEndIndex + 1);
  if (source[nextIndex] === ";" || nextIndex === source.length) return;

  const trivia = source.slice(moduleEndIndex + 1, nextIndex);
  const nextIdentifier = identifierAt(source, nextIndex)?.value;
  assert(
    trivia.includes("\n") &&
      nextIdentifier !== "assert" &&
      nextIdentifier !== "with",
    `upstream ${owner} uses unsupported import syntax`,
  );
}

function unsupportedNamedImport(source, openIndex, expected, owner) {
  const declaration = scanDelimited(source, openIndex, ",", owner);
  assertUnsupportedImportIsIrrelevant(
    declaration.segments.join(","),
    expected,
    owner,
  );
  return declaration.endIndex;
}

function assertUnsupportedImportClauseIsIrrelevant(
  source,
  start,
  expected,
  owner,
) {
  let index = skipTrivia(source, start);
  if (source[index] === "{") {
    unsupportedNamedImport(source, index, expected, owner);
    return;
  }
  if (source[index] === "*") {
    index = skipTrivia(source, index + 1);
    const asKeyword = identifierAt(source, index);
    index = skipTrivia(source, asKeyword?.endIndex ?? index);
    const local = identifierAt(source, index);
    assertUnsupportedImportIsIrrelevant(
      local?.value ?? "",
      expected,
      owner,
    );
    return;
  }

  const local = identifierAt(source, index);
  if (!local) return;
  assertUnsupportedImportIsIrrelevant(local.value, expected, owner);

  index = skipTrivia(source, local.endIndex);
  if (source[index] !== ",") return;
  index = skipTrivia(source, index + 1);
  if (source[index] === "{") {
    unsupportedNamedImport(source, index, expected, owner);
    return;
  }
  if (source[index] === "*") {
    index = skipTrivia(source, index + 1);
    const asKeyword = identifierAt(source, index);
    index = skipTrivia(source, asKeyword?.endIndex ?? index);
    const namespace = identifierAt(source, index);
    assertUnsupportedImportIsIrrelevant(
      namespace?.value ?? "",
      expected,
      owner,
    );
  }
}

export function requireExactTypeImportBinding(source, expected, owner) {
  const code = codeOnly(source);
  const bindings = [];

  for (const declaration of code.matchAll(/^[ \t]*import\b/gm)) {
    const importIndex = declaration.index + declaration[0].indexOf("import");
    let index = skipTrivia(source, importIndex + "import".length);
    if (source[index] === "(" || source[index] === ".") continue;
    if (source[index] === "'" || source[index] === '"') continue;

    const typeKeyword = identifierAt(source, index);
    if (typeKeyword?.value !== "type") {
      assertUnsupportedImportClauseIsIrrelevant(
        source,
        index,
        expected,
        owner,
      );
      continue;
    }

    index = skipTrivia(source, typeKeyword.endIndex);
    if (source[index] !== "{") {
      assertUnsupportedImportClauseIsIrrelevant(
        source,
        index,
        expected,
        owner,
      );
      continue;
    }

    const namedImports = scanDelimited(source, index, ",", owner);
    const importList = source.slice(index + 1, namedImports.endIndex);
    if (!mentionsImportName(importList, expected)) continue;
    const importCode = codeOnly(importList);
    assert(
      !/^\s*,/.test(importCode) && !/,\s*,/.test(importCode),
      `upstream ${owner} uses unsupported import syntax`,
    );
    const specifiers = namedImports.segments.map((segment) => {
      const match = codeOnly(segment).trim().match(
        /^([A-Za-z_$][\w$]*)(?:\s+as\s+([A-Za-z_$][\w$]*))?$/,
      );
      assert(match, `upstream ${owner} uses unsupported import syntax`);
      return {
        imported: match[1],
        local: match[2] ?? match[1],
      };
    });

    index = skipTrivia(source, namedImports.endIndex + 1);
    const fromKeyword = identifierAt(source, index);
    assert(
      fromKeyword?.value === "from",
      `upstream ${owner} uses unsupported import syntax`,
    );
    index = skipTrivia(source, fromKeyword.endIndex);
    const moduleSpecifier = plainModuleSpecifier(source, index, owner);
    assertImportEnd(source, moduleSpecifier.endIndex, owner);

    for (const specifier of specifiers) {
      bindings.push({
        ...specifier,
        module: moduleSpecifier.value,
      });
    }
  }

  const relevant = bindings.filter(
    (binding) =>
      binding.imported === expected.imported ||
      binding.local === expected.local,
  );
  assert.equal(
    relevant.length,
    1,
    `upstream ${owner} must have exactly one relevant type import binding`,
  );
  assert.deepEqual(relevant[0], expected, `upstream ${owner} binding changed`);
}

export function requireExactPropertySignatures(actual, expected, label) {
  assert.deepEqual(
    Object.keys(actual).sort(),
    Object.keys(expected).sort(),
    `${label} fields changed`,
  );
  for (const [name, signature] of Object.entries(expected)) {
    assert.deepEqual(actual[name], signature, `${label}.${name} changed`);
  }
}

export function requireExactInterfaceSignatures(actual, expected, label) {
  requireExactPropertySignatures(actual.methods, expected.methods, `${label} methods`);
  requireExactPropertySignatures(
    actual.properties,
    expected.properties,
    `${label} properties`,
  );
}
