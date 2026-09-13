import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { sessionEventRegistry } from "./schema-snapshot.mjs";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const schemaPath = join(root, "vendor", "copilot", "schemas", "session-events.schema.json");
const outputPath = join(root, "src", "session_event_generated.zig");

const richOverrides = new Map([
  ["assistant.message", {
    payload: "AssistantMessage",
    parser: "parseAssistantMessage",
    fields: [
      "    raw: payloads.RawEvent = .{},",
    ],
    methods: [],
    fieldOverrides: {
      message_id: {
        type: "?[]const u8",
        defaultValue: "null",
        wipeModel: { kind: "nullable", child: { kind: "string" } },
      },
    },
  }],
  ["assistant.message_delta", {
    payload: "AssistantMessageDelta",
    parser: "parseAssistantMessageDelta",
    fields: [
      "    raw: payloads.RawEvent = .{},",
    ],
    methods: [],
  }],
  ["assistant.reasoning", {
    payload: "AssistantReasoning",
    parser: "parseAssistantReasoning",
    fields: [
      "    raw: payloads.RawEvent = .{},",
    ],
    methods: [],
  }],
  ["assistant.reasoning_delta", {
    payload: "AssistantReasoningDelta",
    parser: "parseAssistantReasoningDelta",
    fields: [
      "    raw: payloads.RawEvent = .{},",
    ],
    methods: [],
  }],
  ["session.idle", {
    payload: "SessionIdle",
    parser: "parseSessionIdle",
    fields: [
      "    raw: payloads.RawEvent = .{},",
    ],
    methods: [],
    fieldOverrides: {
      mode: {
        type: "?[]const u8",
        defaultValue: "null",
        assignment: "if (parsed.mode) |mode| try arena.allocator().dupe(u8, @tagName(mode)) else null",
        wipeModel: { kind: "nullable", child: { kind: "string" } },
      },
    },
  }],
  ["session.error", {
    payload: "SessionError",
    parser: "parseSessionError",
    fields: [
      "    raw: payloads.RawEvent = .{},",
    ],
    methods: [],
  }],
  ["permission.requested", {
    payload: "PermissionRequested",
    parser: "parsePermissionRequested",
    fields: [
      "    permission_request_json: []u8,",
      "    managed_approval_required: bool = false,",
      "    automatic_handling: payloads.AutomaticPermissionHandling = .not_configured,",
      "    raw: payloads.RawEvent = .{},",
    ],
    methods: [
      "    pub fn kind(self: PermissionRequested) !payloads.PermissionRequestKind {",
      "        const parsed = try std.json.parseFromSlice(",
      "            struct { kind: []const u8 },",
      "            std.heap.page_allocator,",
      "            self.permission_request_json,",
      "            .{ .ignore_unknown_fields = true },",
      "        );",
      "        defer parsed.deinit();",
      "        return payloads.PermissionRequestKind.fromString(parsed.value.kind);",
      "    }",
      "",
      "    pub fn parseRequest(",
      "        self: PermissionRequested,",
      "        comptime T: type,",
      "        allocator: std.mem.Allocator,",
      "    ) !std.json.Parsed(T) {",
      "        return std.json.parseFromSlice(T, allocator, self.permission_request_json, .{",
      "            .allocate = .alloc_always,",
      "            .ignore_unknown_fields = true,",
      "        });",
      "    }",
    ],
    cleanup: [
      "        @memset(self.permission_request_json, 0);",
      "        allocator.free(self.permission_request_json);",
    ],
    fieldOverrides: {
      permission_request: {
        type: "?PermissionRequest",
        defaultValue: "null",
        assignment: "parsed.permission_request",
        wipeModel: { kind: "nullable", child: { kind: "ref", target: "PermissionRequest" } },
      },
    },
  }],
  ["external_tool.requested", {
    payload: "ExternalToolRequested",
    parser: "parseExternalToolRequested",
    fields: [
      "    arguments_json: []u8,",
      "    raw: payloads.RawEvent = .{},",
    ],
    methods: [
      "    pub fn parseArguments(",
      "        self: ExternalToolRequested,",
      "        comptime T: type,",
      "        allocator: std.mem.Allocator,",
      "    ) !std.json.Parsed(T) {",
      "        return std.json.parseFromSlice(T, allocator, self.arguments_json, .{",
      "            .allocate = .alloc_always,",
      "            .ignore_unknown_fields = true,",
      "        });",
      "    }",
    ],
    cleanup: [
      "        @memset(self.arguments_json, 0);",
      "        allocator.free(self.arguments_json);",
    ],
  }],
]);

const ignoredKeywords = new Set([
  "contentEncoding",
  "default",
  "deprecated",
  "description",
  "format",
  "stability",
  "title",
  "visibility",
  "x-enumDescriptions",
]);
const shapeKeywords = new Set([
  "$ref",
  "additionalProperties",
  "anyOf",
  "const",
  "enum",
  "exclusiveMinimum",
  "items",
  "maxLength",
  "maximum",
  "minItems",
  "minLength",
  "minimum",
  "properties",
  "required",
  "type",
  "x-opaque-json",
]);
const zigKeywords = new Set([
  "align", "allowzero", "and", "anyframe", "anytype", "asm", "async", "await",
  "break", "callconv", "catch", "comptime", "const", "continue", "defer", "else",
  "enum", "errdefer", "error", "export", "extern", "fn", "for", "if", "inline",
  "linksection", "noalias", "noinline", "nosuspend", "opaque", "or", "orelse",
  "packed", "pub", "resume", "return", "struct", "suspend", "switch", "test",
  "threadlocal", "try", "union", "unreachable", "usingnamespace", "var", "volatile",
  "while",
]);

function zigTag(value) {
  let result = value
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
    .replace(/[^A-Za-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .toLowerCase();
  if (!result || /^[0-9]/.test(result)) result = `_${result}`;
  if (zigKeywords.has(result)) result += "_";
  return result;
}

function typeName(value) {
  const result = value
    .replace(/[^A-Za-z0-9]+/g, " ")
    .trim()
    .split(/\s+/)
    .filter(Boolean)
    .map((part) => part[0].toUpperCase() + part.slice(1))
    .join("");
  if (!result) throw new Error(`cannot create Zig type name from ${JSON.stringify(value)}`);
  return /^[0-9]/.test(result) ? `_${result}` : result;
}

function zigString(value) {
  return JSON.stringify(value);
}

function indent(value, spaces = 4) {
  const prefix = " ".repeat(spaces);
  return value.split("\n").map((line) => line ? `${prefix}${line}` : line).join("\n");
}

function formatZig(source) {
  const result = spawnSync("zig", ["fmt", "--stdin"], {
    input: source,
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const line = Number(result.stderr.match(/<stdin>:(\d+):/)?.[1]);
    const lines = source.split("\n");
    const excerpt = Number.isFinite(line)
      ? lines.slice(Math.max(0, line - 4), line + 3).join("\n")
      : "";
    throw new Error(`zig fmt failed while generating session events:\n${result.stderr}${excerpt}`);
  }
  return result.stdout;
}

class SchemaModel {
  constructor(schema) {
    this.schema = schema;
    this.definitions = schema.definitions ?? {};
    this.nodes = new Map();
    this.names = new Map();
    this.visiting = new Set();
  }

  checkKeywords(node, path) {
    for (const keyword of Object.keys(node)) {
      if (!shapeKeywords.has(keyword) && !ignoredKeywords.has(keyword)) {
        throw new Error(`unsupported schema keyword ${keyword} at ${path}`);
      }
    }
  }

  reserveName(name, path) {
    const previous = this.names.get(name);
    if (previous && previous !== path) {
      throw new Error(`generated Zig type collision ${name}: ${previous} and ${path}`);
    }
    this.names.set(name, path);
  }

  definition(name) {
    if (!this.definitions[name]) throw new Error(`missing schema definition: ${name}`);
    if (this.nodes.has(name)) return this.nodes.get(name);
    if (this.visiting.has(name)) throw new Error(`cyclic schema reference at ${name}`);
    this.visiting.add(name);
    this.reserveName(name, `#/definitions/${name}`);
    const model = this.node(this.definitions[name], name, `#/definitions/${name}`, true);
    model.name ??= name;
    this.nodes.set(name, model);
    this.visiting.delete(name);
    return model;
  }

  node(node, suggestedName, path, publicType = false) {
    if (!node || typeof node !== "object" || Array.isArray(node)) {
      throw new Error(`invalid schema node at ${path}`);
    }
    this.checkKeywords(node, path);

    if (node.$ref) {
      const prefix = "#/definitions/";
      if (!node.$ref.startsWith(prefix)) {
        throw new Error(`unsupported non-local reference ${node.$ref} at ${path}`);
      }
      const target = node.$ref.slice(prefix.length);
      this.definition(target);
      return { kind: "ref", target };
    }

    if (node["x-opaque-json"] === true) return { kind: "opaque" };

    const types = Array.isArray(node.type) ? node.type : null;
    if (types) {
      const nonNull = types.filter((entry) => entry !== "null");
      if (types.length !== 2 || nonNull.length !== 1) {
        throw new Error(`unsupported type union ${JSON.stringify(types)} at ${path}`);
      }
      return {
        kind: "nullable",
        child: this.node({ ...node, type: nonNull[0] }, suggestedName, path),
      };
    }

    if (node.anyOf) {
      if (!Array.isArray(node.anyOf) || node.anyOf.length === 0) {
        throw new Error(`empty anyOf at ${path}`);
      }
      const nonNull = node.anyOf.filter((entry) => entry.type !== "null");
      if (node.anyOf.length === 2 && nonNull.length === 1) {
        return {
          kind: "nullable",
          child: this.node(nonNull[0], suggestedName, `${path}/anyOf`),
        };
      }
      const name = typeName(suggestedName);
      if (!publicType) this.reserveName(name, path);
      const branches = node.anyOf.map((entry, index) => ({
        schema: entry,
        model: this.node(entry, `${name}Variant${index + 1}`, `${path}/anyOf/${index}`, false),
      }));
      const selection = this.unionSelection(branches, path);
      const model = { kind: "union", name, branches, selection };
      if (!publicType) this.nodes.set(name, model);
      return model;
    }

    if (node.enum) {
      if (node.type !== "string" || !node.enum.every((entry) => typeof entry === "string")) {
        throw new Error(`only string enums are supported at ${path}`);
      }
      const name = typeName(suggestedName);
      if (!publicType) this.reserveName(name, path);
      const seen = new Map();
      const values = node.enum.map((wire) => {
        const tag = zigTag(wire);
        if (seen.has(tag)) {
          throw new Error(`enum tag collision ${tag}: ${seen.get(tag)} and ${wire} at ${path}`);
        }
        seen.set(tag, wire);
        return { wire, tag };
      });
      const model = { kind: "enum", name, values };
      if (!publicType) this.nodes.set(name, model);
      return model;
    }

    if (node.const !== undefined) {
      if (typeof node.const !== "string") {
        throw new Error(`only string constants are supported at ${path}`);
      }
      return { kind: "constant", value: node.const };
    }

    switch (node.type) {
      case "string":
        return { kind: "string", minLength: node.minLength, maxLength: node.maxLength };
      case "boolean":
        return { kind: "boolean" };
      case "integer":
        return {
          kind: "integer",
          unsigned: (node.minimum ?? node.exclusiveMinimum ?? -1) >= 0,
          minimum: node.minimum,
          exclusiveMinimum: node.exclusiveMinimum,
          maximum: node.maximum,
        };
      case "number":
        return {
          kind: "number",
          minimum: node.minimum,
          exclusiveMinimum: node.exclusiveMinimum,
          maximum: node.maximum,
        };
      case "array": {
        if (!node.items) throw new Error(`array has no items at ${path}`);
        return {
          kind: "array",
          child: this.node(node.items, `${suggestedName}Item`, `${path}/items`),
          minItems: node.minItems,
        };
      }
      case "object": {
        const properties = node.properties ?? {};
        if (Object.keys(properties).length === 0 &&
            node.additionalProperties &&
            typeof node.additionalProperties === "object") {
          return {
            kind: "map",
            child: this.node(
              node.additionalProperties,
              `${suggestedName}Value`,
              `${path}/additionalProperties`,
            ),
          };
        }
        const name = typeName(suggestedName);
        if (!publicType) this.reserveName(name, path);
        const required = new Set(node.required ?? []);
        const fieldNames = new Map();
        const fields = Object.entries(properties).map(([wire, property]) => {
          const field = zigTag(wire);
          if (fieldNames.has(field)) {
            throw new Error(
              `field name collision ${field}: ${fieldNames.get(field)} and ${wire} at ${path}`,
            );
          }
          fieldNames.set(field, wire);
          return {
            wire,
            field,
            required: required.has(wire),
            model: this.node(property, `${name}${typeName(wire)}`, `${path}/properties/${wire}`),
          };
        });
        for (const requiredField of required) {
          if (!Object.hasOwn(properties, requiredField)) {
            throw new Error(`required property ${requiredField} is not declared at ${path}`);
          }
        }
        const additional = node.additionalProperties;
        if (additional !== undefined && additional !== false && additional !== true) {
          throw new Error(`mixed properties and typed additionalProperties at ${path}`);
        }
        const model = {
          kind: "object",
          name,
          fields,
          rejectUnknown: additional === false,
        };
        if (!publicType) this.nodes.set(name, model);
        return model;
      }
      default:
        throw new Error(`unsupported schema construct at ${path}: ${JSON.stringify(node)}`);
    }
  }

  resolvedSchema(schema) {
    if (!schema.$ref) return schema;
    return this.definitions[schema.$ref.slice("#/definitions/".length)];
  }

  unionSelection(branches, path) {
    const branchSchemas = branches.map((branch) => this.resolvedSchema(branch.schema));
    const propertySets = branchSchemas.map((schema) => schema.properties ?? {});
    const commonKeys = Object.keys(propertySets[0] ?? {}).filter((key) =>
      propertySets.every((properties) => Object.hasOwn(properties, key))
    );
    for (const key of commonKeys) {
      const values = propertySets.map((properties) => properties[key].const);
      if (values.every((value) => typeof value === "string") &&
          new Set(values).size === values.length) {
        const tags = values.map(zigTag);
        if (new Set(tags).size !== tags.length) {
          throw new Error(`normalized anyOf discriminator collision at ${path}`);
        }
        return {
          kind: "discriminator",
          key,
          values,
          tags,
        };
      }
    }

    const requiredSets = branchSchemas.map((schema) => new Set(schema.required ?? []));
    const selectors = requiredSets.map((required, index) =>
      [...required].find((key) =>
        requiredSets.every((other, otherIndex) => otherIndex === index || !other.has(key))
      )
    );
    if (selectors.every(Boolean) && new Set(selectors).size === selectors.length) {
      const tags = selectors.map(zigTag);
      if (new Set(tags).size !== tags.length) {
        throw new Error(`normalized anyOf selector collision at ${path}`);
      }
      return {
        kind: "required_key",
        keys: selectors,
        tags,
      };
    }
    throw new Error(`anyOf branches are not selectable at ${path}`);
  }
}

function zigType(model) {
  switch (model.kind) {
    case "ref":
      return model.target;
    case "string":
    case "constant":
      return "[]const u8";
    case "boolean":
      return "bool";
    case "integer":
      return model.unsigned ? "u64" : "i64";
    case "number":
      return "f64";
    case "opaque":
      return "std.json.Value";
    case "nullable":
      return `?${zigType(model.child)}`;
    case "array":
      return `[]const ${zigType(model.child)}`;
    case "map":
      return `std.json.ArrayHashMap(${zigType(model.child)})`;
    case "enum":
    case "object":
    case "union":
      return model.name;
    default:
      throw new Error(`missing Zig type for ${model.kind}`);
  }
}

function parseExpression(model, value, allocator) {
  switch (model.kind) {
    case "ref":
      return `try parse${model.target}(${allocator}, ${value})`;
    case "string":
      return `try parseString(${allocator}, ${value}, ${model.minLength ?? "null"}, ${model.maxLength ?? "null"})`;
    case "constant":
      return `try parseConstant(${allocator}, ${value}, ${zigString(model.value)})`;
    case "boolean":
      return `try parseBool(${value})`;
    case "integer":
      return `try parseInteger(${zigType(model)}, ${value}, ${model.minimum ?? "null"}, ${model.exclusiveMinimum ?? "null"}, ${model.maximum ?? "null"})`;
    case "number":
      return `try parseNumber(${value}, ${model.minimum ?? "null"}, ${model.exclusiveMinimum ?? "null"}, ${model.maximum ?? "null"})`;
    case "opaque":
      return `try cloneJsonValue(${allocator}, ${value})`;
    case "nullable":
      return `if ((${value}) == .null) null else ${parseExpression(model.child, value, allocator)}`;
    case "array":
      return `try parse${model.helperName}(${allocator}, ${value})`;
    case "map":
      return `try parse${model.helperName}(${allocator}, ${value})`;
    case "enum":
    case "object":
    case "union":
      return `try parse${model.name}(${allocator}, ${value})`;
    default:
      throw new Error(`missing parser for ${model.kind}`);
  }
}

function parseUsesAllocator(model) {
  switch (model.kind) {
    case "string":
    case "constant":
    case "opaque":
    case "array":
    case "map":
    case "ref":
      return true;
    case "nullable":
      return parseUsesAllocator(model.child);
    case "object":
      return model.fields.some((field) => parseUsesAllocator(field.model));
    case "union":
      return model.branches.some((branch) => parseUsesAllocator(branch.model));
    case "enum":
    case "boolean":
    case "integer":
    case "number":
      return false;
    default:
      throw new Error(`missing allocator rule for ${model.kind}`);
  }
}

function assignHelperNames(model, path, seen = new Set()) {
  if (!model || seen.has(model)) return;
  seen.add(model);
  if (model.kind === "array" || model.kind === "map") {
    model.helperName ??= `${typeName(path)}${model.kind === "array" ? "Array" : "Map"}`;
    assignHelperNames(model.child, `${path}Item`, seen);
  } else if (model.kind === "nullable") {
    assignHelperNames(model.child, path, seen);
  } else if (model.kind === "union") {
    model.branches.forEach((branch, index) =>
      assignHelperNames(branch.model, `${path}Variant${index + 1}`, seen)
    );
  } else if (model.kind === "object") {
    model.fields.forEach((field) =>
      assignHelperNames(field.model, `${path}${typeName(field.wire)}`, seen)
    );
  }
}

function collectHelpers(model, helpers, seen = new Set()) {
  if (!model || seen.has(model)) return;
  seen.add(model);
  if (model.kind === "array" || model.kind === "map") {
    helpers.set(model.helperName, model);
    collectHelpers(model.child, helpers, seen);
  } else if (model.kind === "nullable") {
    collectHelpers(model.child, helpers, seen);
  } else if (model.kind === "union") {
    model.branches.forEach((branch) => collectHelpers(branch.model, helpers, seen));
  } else if (model.kind === "object") {
    model.fields.forEach((field) => collectHelpers(field.model, helpers, seen));
  }
}

function renderType(model) {
  if (model.kind === "enum") {
    return `pub const ${model.name} = enum {
${model.values.map((value) => `    ${value.tag},`).join("\n")}
};`;
  }
  if (model.kind === "union") {
    return `pub const ${model.name} = union(enum) {
${model.branches.map((branch, index) =>
    `    ${model.selection.tags[index]}: ${zigType(branch.model)},`
  ).join("\n")}
};`;
  }
  if (model.kind === "object") {
    return `pub const ${model.name} = struct {
${model.fields.map((field) => {
    const optional = !field.required && field.model.kind !== "nullable";
    return `    ${field.field}: ${optional ? "?" : ""}${zigType(field.model)}${optional ? " = null" : ""},`;
  }).join("\n")}
};`;
  }
  return `pub const ${model.name} = ${zigType(model)};`;
}

function renderObjectParser(model) {
  const declarations = model.fields.map((field) => {
    const source = `object.get(${zigString(field.wire)})`;
    const effectiveModel = !field.required && field.model.kind !== "nullable"
      ? { kind: "nullable", child: field.model }
      : field.model;
    const expression = field.required
      ? parseExpression(
        field.model,
        `${source} orelse return error.InvalidSessionEvent`,
        "allocator",
      )
      : `if (${source}) |field_value| ${parseExpression(
        field.model,
        "field_value",
        "allocator",
      )} else null`;
    const cleanup = wipeStatement(effectiveModel, `cleanup_${field.field}`);
    const cleanupBinding = wipeNeedsMutable(effectiveModel) ? "var" : "const";
    return `const parsed_${field.field} = ${expression};${cleanup ? `\n    errdefer {\n        ${cleanupBinding} cleanup_${field.field} = parsed_${field.field};\n${indent(cleanup, 8)}\n    }` : ""}`;
  }).join("\n    ");
  const assignments = model.fields.map((field) => {
    if (field.required) {
      return `        .${field.field} = parsed_${field.field},`;
    }
    return `        .${field.field} = parsed_${field.field},`;
  }).join("\n");
  const objectUsed = model.fields.length > 0;
  return `fn parse${model.name}(${parseUsesAllocator(model) ? "allocator" : "_"}: std.mem.Allocator, value: std.json.Value) !${model.name} {
    ${objectUsed ? "const object =" : "_ ="} try payloads.requiredObject(value);
    ${declarations}
    return .{
${assignments}
    };
}`;
}

function renderParser(model) {
  if (model.kind === "object") return renderObjectParser(model);
  if (model.kind === "enum") {
    return `fn parse${model.name}(_: std.mem.Allocator, value: std.json.Value) !${model.name} {
    const wire = try valueString(value);
${model.values.map((entry) =>
    `    if (std.mem.eql(u8, wire, ${zigString(entry.wire)})) return .${entry.tag};`
  ).join("\n")}
    return error.InvalidSessionEvent;
}`;
  }
  if (model.kind === "union") {
    if (model.selection.kind === "discriminator") {
      return `fn parse${model.name}(${parseUsesAllocator(model) ? "allocator" : "_"}: std.mem.Allocator, value: std.json.Value) !${model.name} {
    const object = try payloads.requiredObject(value);
    const discriminator = try payloads.requiredString(object, ${zigString(model.selection.key)});
${model.branches.map((branch, index) =>
    `    if (std.mem.eql(u8, discriminator, ${zigString(model.selection.values[index])})) return .{ .${model.selection.tags[index]} = ${parseExpression(branch.model, "value", "allocator")} };`
  ).join("\n")}
    return error.InvalidSessionEvent;
}`;
    }
    return `fn parse${model.name}(${parseUsesAllocator(model) ? "allocator" : "_"}: std.mem.Allocator, value: std.json.Value) !${model.name} {
    const object = try payloads.requiredObject(value);
    var matching_branches: usize = 0;
${model.selection.keys.map((key) =>
    `    if (object.get(${zigString(key)}) != null) matching_branches += 1;`
  ).join("\n")}
    if (matching_branches != 1) return error.InvalidSessionEvent;
${model.branches.map((branch, index) =>
    `    if (object.get(${zigString(model.selection.keys[index])}) != null) return .{ .${model.selection.tags[index]} = ${parseExpression(branch.model, "value", "allocator")} };`
  ).join("\n")}
    return error.InvalidSessionEvent;
}`;
  }
  return `fn parse${model.name}(${parseUsesAllocator(model) ? "allocator" : "_"}: std.mem.Allocator, value: std.json.Value) !${model.name} {
    return ${parseExpression({ ...model, kind: model.kind }, "value", "allocator")};
}`;
}

function renderHelper(model) {
  if (model.kind === "array") {
    const cleanup = wipeStatement(model.child, "item.*");
    return `fn parse${model.helperName}(allocator: std.mem.Allocator, value: std.json.Value) !${zigType(model)} {
    const source = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidSessionEvent,
    };
    if (source.len < ${model.minItems ?? 0}) return error.InvalidSessionEvent;
    const result = try allocator.alloc(${zigType(model.child)}, source.len);
${cleanup ? `    var initialized: usize = 0;\n    errdefer for (@constCast(result[0..initialized])) |*item| {\n${indent(cleanup, 8)}\n    };` : ""}
    for (source, result) |item, *destination| {
        destination.* = ${parseExpression(model.child, "item", "allocator")};
${cleanup ? "        initialized += 1;" : ""}
    }
    return result;
}`;
  }
  const cleanup = wipeStatement(model.child, "cleanup_value");
  const cleanupBinding = wipeNeedsMutable(model.child) ? "var" : "const";
  return `fn parse${model.helperName}(allocator: std.mem.Allocator, value: std.json.Value) !${zigType(model)} {
    const source = try payloads.requiredObject(value);
    var result: ${zigType(model)} = .{};
    errdefer {
        var cleanup_iterator = result.map.iterator();
        while (cleanup_iterator.next()) |entry| {
            wipeString(entry.key_ptr.*);
${indent(wipeStatement(model.child, "entry.value_ptr.*"), 12)}
        }
    }
    var iterator = source.iterator();
    while (iterator.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer wipeString(key);
        const parsed_value = ${parseExpression(model.child, "entry.value_ptr.*", "allocator")};
${cleanup ? `        errdefer {\n            ${cleanupBinding} cleanup_value = parsed_value;\n${indent(cleanup, 12)}\n        }` : ""}
        try result.map.put(allocator, key, parsed_value);
    }
    return result;
}`;
}

function wipeStatement(model, expression) {
  switch (model.kind) {
    case "ref":
      return `wipe${model.target}(&${expression});`;
    case "string":
    case "constant":
      return `wipeString(${expression});`;
    case "opaque":
      return `wipeJsonValue(&${expression});`;
    case "nullable":
      {
        const child = wipeStatement(model.child, "present.*");
        return child ? `if (${expression}) |*present| {\n${indent(child)}\n}` : "";
      }
    case "array": {
      const child = wipeStatement(model.child, "item.*");
      return child ? `for (@constCast(${expression})) |*item| {\n${indent(child)}\n}` : "";
    }
    case "map":
      return `{
    var iterator = ${expression}.map.iterator();
    while (iterator.next()) |entry| {
        wipeString(entry.key_ptr.*);
${indent(wipeStatement(model.child, "entry.value_ptr.*"), 8)}
    }
}`;
    case "object":
    case "union":
      return `wipe${model.name}(&${expression});`;
    case "enum":
    case "boolean":
    case "integer":
    case "number":
      return "";
    default:
      throw new Error(`missing wipe for ${model.kind}`);
  }
}

function wipeNeedsMutable(model) {
  switch (model.kind) {
    case "ref":
    case "opaque":
    case "map":
    case "object":
    case "union":
      return true;
    case "nullable":
      return Boolean(wipeStatement(model.child, "value"));
    case "array":
    case "string":
    case "constant":
    case "enum":
    case "boolean":
    case "integer":
    case "number":
      return false;
    default:
      throw new Error(`missing wipe mutability rule for ${model.kind}`);
  }
}

function renderWiper(model) {
  if (model.kind === "object") {
    const body = model.fields
      .map((field) => {
        const optional = !field.required && field.model.kind !== "nullable";
        return optional
          ? wipeStatement({ kind: "nullable", child: field.model }, `value.${field.field}`)
          : wipeStatement(field.model, `value.${field.field}`);
      })
      .filter(Boolean)
      .join("\n");
    return `fn wipe${model.name}(value: *${model.name}) void {
${indent(body || "_ = value;")}
}`;
  }
  if (model.kind === "union") {
    return `fn wipe${model.name}(value: *${model.name}) void {
    switch (value.*) {
${model.branches.map((branch, index) => {
    const statement = wipeStatement(branch.model, "payload.*");
    return statement
      ? `        .${model.selection.tags[index]} => |*payload| {\n${indent(statement, 12)}\n        },`
      : `        .${model.selection.tags[index]} => {},`;
  }).join("\n")}
    }
}`;
  }
  const statement = wipeStatement(model, "value.*");
  return `fn wipe${model.name}(value: *${model.name}) void {
${indent(statement || "_ = value;")}
}`;
}

function freeStatement(model, expression) {
  switch (model.kind) {
    case "ref":
      return `free${model.target}(&${expression}, allocator);`;
    case "string":
    case "constant":
      return `wipeString(${expression});\nallocator.free(@constCast(${expression}));`;
    case "opaque":
      return `freeJsonValue(&${expression}, allocator);`;
    case "nullable": {
      const child = freeStatement(model.child, "present.*");
      return child ? `if (${expression}) |*present| {\n${indent(child)}\n}` : "";
    }
    case "array": {
      const child = freeStatement(model.child, "item.*");
      const items = child
        ? `for (@constCast(${expression})) |*item| {\n${indent(child)}\n}\n`
        : "";
      return `${items}allocator.free(@constCast(${expression}));`;
    }
    case "map":
      return `{
    var iterator = ${expression}.map.iterator();
    while (iterator.next()) |entry| {
        wipeString(entry.key_ptr.*);
        allocator.free(@constCast(entry.key_ptr.*));
${indent(freeStatement(model.child, "entry.value_ptr.*"), 8)}
    }
    ${expression}.deinit(allocator);
}`;
    case "object":
    case "union":
      return `free${model.name}(&${expression}, allocator);`;
    case "enum":
    case "boolean":
    case "integer":
    case "number":
      return "";
    default:
      throw new Error(`missing free for ${model.kind}`);
  }
}

function renderFreer(model) {
  if (model.kind === "object") {
    const body = model.fields
      .map((field) => {
        const optional = !field.required && field.model.kind !== "nullable";
        return optional
          ? freeStatement({ kind: "nullable", child: field.model }, `value.${field.field}`)
          : freeStatement(field.model, `value.${field.field}`);
      })
      .filter(Boolean)
      .join("\n");
    return `fn free${model.name}(value: *${model.name}, allocator: std.mem.Allocator) void {
${indent(body || "_ = value;\n_ = allocator;")}
}`;
  }
  if (model.kind === "union") {
    const usesAllocator = model.branches.some((branch) => freeStatement(branch.model, "payload.*"));
    return `fn free${model.name}(value: *${model.name}, ${usesAllocator ? "allocator" : "_"}: std.mem.Allocator) void {
    switch (value.*) {
${model.branches.map((branch, index) => {
    const statement = freeStatement(branch.model, "payload.*");
    return statement
      ? `        .${model.selection.tags[index]} => |*payload| {\n${indent(statement, 12)}\n        },`
      : `        .${model.selection.tags[index]} => {},`;
  }).join("\n")}
    }
}`;
  }
  const statement = freeStatement(model, "value.*");
  return `fn free${model.name}(value: *${model.name}, ${statement ? "allocator" : "_"}: std.mem.Allocator) void {
${indent(statement || "_ = value;")}
}`;
}

function minimalValue(node, definitions) {
  if (node.$ref) return minimalValue(definitions[node.$ref.slice("#/definitions/".length)], definitions);
  if (node["x-opaque-json"] === true) return null;
  if (node.const !== undefined) return node.const;
  if (node.enum) return node.enum[0];
  if (node.anyOf) {
    return minimalValue(node.anyOf.find((entry) => entry.type !== "null") ?? node.anyOf[0], definitions);
  }
  if (Array.isArray(node.type)) {
    return node.type.includes("null") ? null : minimalValue({ ...node, type: node.type[0] }, definitions);
  }
  switch (node.type) {
    case "object": {
      const result = {};
      for (const field of node.required ?? []) {
        result[field] = minimalValue(node.properties[field], definitions);
      }
      return result;
    }
    case "array":
      return Array.from({ length: node.minItems ?? 0 }, () => minimalValue(node.items, definitions));
    case "string":
      return "x".repeat(node.minLength ?? 0);
    case "boolean":
      return false;
    case "integer": {
      const minimum = node.minimum ?? (node.exclusiveMinimum !== undefined
        ? node.exclusiveMinimum + 1
        : 0);
      return Math.max(0, minimum);
    }
    case "number":
      return node.minimum ?? (node.exclusiveMinimum !== undefined ? node.exclusiveMinimum + 1 : 0);
    default:
      throw new Error(`cannot create minimal value for ${JSON.stringify(node)}`);
  }
}

export function buildRegistry(schema) {
  const model = new SchemaModel(schema);
  const entries = sessionEventRegistry(schema);
  const discriminators = new Map();
  const tags = new Map();

  for (const entry of entries) {
    if (!schema.definitions?.[entry.dataDefinitionName]) {
      throw new Error(
        `${entry.definitionName} references missing data definition: ${entry.dataDefinitionName}`,
      );
    }
    if (discriminators.has(entry.discriminator)) {
      throw new Error(`duplicate session event discriminator: ${entry.discriminator}`);
    }
    discriminators.set(entry.discriminator, entry.definitionName);
    const tag = zigTag(entry.discriminator);
    if (tag === "unknown") {
      throw new Error(`session event discriminator normalizes to reserved tag: ${entry.discriminator}`);
    }
    const collided = tags.get(tag);
    if (collided) {
      throw new Error(`session event tag collision ${tag}: ${collided} and ${entry.discriminator}`);
    }
    tags.set(tag, entry.discriminator);
    entry.tag = tag;
    entry.rich = richOverrides.get(entry.discriminator) ?? null;
    entry.dataModel = model.definition(entry.dataDefinitionName);
    entry.payload = entry.rich?.payload ?? `${typeName(entry.definitionName)}Payload`;
  }

  for (const discriminator of richOverrides.keys()) {
    if (!discriminators.has(discriminator)) {
      throw new Error(`missing rich session event override: ${discriminator}`);
    }
  }

  for (const [name, node] of model.nodes) assignHelperNames(node, name);
  return { entries, model };
}

function renderRichType(entry) {
  const data = entry.dataModel;
  if (data.kind !== "object") {
    throw new Error(`rich override ${entry.discriminator} does not reference an object`);
  }
  const fields = data.fields.map((field) => {
    const override = entry.rich.fieldOverrides?.[field.field];
    if (override) {
      return `    ${field.field}: ${override.type}${override.defaultValue !== undefined ? ` = ${override.defaultValue}` : ""},`;
    }
    const optional = !field.required && field.model.kind !== "nullable";
    return `    ${field.field}: ${optional ? "?" : ""}${zigType(field.model)}${optional ? " = null" : ""},`;
  });
  return `pub const ${entry.payload} = struct {
${fields.join("\n")}
${entry.rich.fields.join("\n")}
    arena: ?std.heap.ArenaAllocator = null,

${entry.rich.methods.join("\n")}
${entry.rich.methods.length ? "\n" : ""}
    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        var owned = self;
        if (owned.arena) |*arena| {
            wipe${data.name}Fields(&owned);
            arena.deinit();
        } else {
            free${data.name}Fields(&owned, allocator);
        }
${(entry.rich.cleanup ?? []).join("\n")}
        owned.raw.deinit(allocator);
    }
};`;
}

function renderRichFieldsWiper(entry) {
  const statements = entry.dataModel.fields
    .map((field) => {
      const override = entry.rich.fieldOverrides?.[field.field];
      if (override) return wipeStatement(override.wipeModel, `value.${field.field}`);
      const optional = !field.required && field.model.kind !== "nullable";
      return optional
        ? wipeStatement({ kind: "nullable", child: field.model }, `value.${field.field}`)
        : wipeStatement(field.model, `value.${field.field}`);
    })
    .filter(Boolean)
    .join("\n");
  return `fn wipe${entry.dataModel.name}Fields(value: *${entry.payload}) void {
${indent(statements || "_ = value;")}
}`;
}

function renderRichFieldsFreer(entry) {
  const statements = entry.dataModel.fields
    .map((field) => {
      const override = entry.rich.fieldOverrides?.[field.field];
      if (override) return freeStatement(override.wipeModel, `value.${field.field}`);
      const optional = !field.required && field.model.kind !== "nullable";
      return optional
        ? freeStatement({ kind: "nullable", child: field.model }, `value.${field.field}`)
        : freeStatement(field.model, `value.${field.field}`);
    })
    .filter(Boolean)
    .join("\n");
  return `fn free${entry.dataModel.name}Fields(
    value: *${entry.payload},
    allocator: std.mem.Allocator,
) void {
${indent(statements || "_ = value;\n_ = allocator;")}
}`;
}

function renderRichParser(entry) {
  const data = entry.dataModel;
  const assignments = data.fields.map((field) =>
    `        .${field.field} = ${entry.rich.fieldOverrides?.[field.field]?.assignment ?? `parsed.${field.field}`},`
  );
  const extras = [];
  if (entry.discriminator === "permission.requested") {
    extras.push(
      "        .permission_request_json = helper_json,",
      "        .managed_approval_required = try managedApprovalRequired(data),",
    );
  }
  if (entry.discriminator === "external_tool.requested") {
    extras.push(
      "        .arguments_json = helper_json,",
    );
  }
  const futurePermission = entry.discriminator === "permission.requested"
    ? `    const request_value = data.get("permissionRequest") orelse return error.InvalidSessionEvent;
    const request_object = try payloads.requiredObject(request_value);
    const request_kind = try payloads.requiredString(request_object, "kind");
    if (!isKnownPermissionRequestKind(request_kind)) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const parsed_request_id = try parseString(arena.allocator(), data.get("requestId") orelse return error.InvalidSessionEvent, null, null);
        errdefer wipeString(parsed_request_id);
        const parsed_prompt_request = if (data.get("promptRequest")) |field_value| try parsePermissionPromptRequest(arena.allocator(), field_value) else null;
        errdefer {
            var cleanup_prompt_request = parsed_prompt_request;
            if (cleanup_prompt_request) |*present| wipePermissionPromptRequest(&present.*);
        }
        const parsed_agent_mode = if (data.get("agentMode")) |field_value| try parseSessionMode(arena.allocator(), field_value) else null;
        const parsed_risk_assessment = if (data.get("riskAssessment")) |field_value| try cloneJsonValue(arena.allocator(), field_value) else null;
        errdefer {
            var cleanup_risk_assessment = parsed_risk_assessment;
            if (cleanup_risk_assessment) |*present| wipeJsonValue(&present.*);
        }
        const parsed_resolved_by_hook = if (data.get("resolvedByHook")) |field_value| try parseBool(field_value) else null;
        const helper_json = try std.json.Stringify.valueAlloc(allocator, request_value, .{});
        errdefer {
            @memset(helper_json, 0);
            allocator.free(helper_json);
        }
        return .{
            .request_id = parsed_request_id,
            .permission_request = null,
            .prompt_request = parsed_prompt_request,
            .agent_mode = parsed_agent_mode,
            .risk_assessment = parsed_risk_assessment,
            .resolved_by_hook = parsed_resolved_by_hook,
            .permission_request_json = helper_json,
            .managed_approval_required = try managedApprovalRequired(data),
            .raw = raw.take(),
            .arena = arena,
        };
    }
`
    : "";
  return `fn ${entry.rich.parser}(
    allocator: std.mem.Allocator,
    data: std.json.ObjectMap,
    raw: *payloads.RawEvent,
) !${entry.payload} {
${futurePermission}    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
var parsed = try parse${data.name}(arena.allocator(), .{ .object = data });
errdefer wipe${data.name}(&parsed);
${entry.discriminator === "permission.requested" ? "    const helper_json = try std.json.Stringify.valueAlloc(allocator, data.get(\"permissionRequest\").?, .{});\n    errdefer {\n        @memset(helper_json, 0);\n        allocator.free(helper_json);\n    }" : ""}
${entry.discriminator === "external_tool.requested" ? "    const helper_json = try std.json.Stringify.valueAlloc(allocator, data.get(\"arguments\") orelse .null, .{});\n    errdefer {\n        @memset(helper_json, 0);\n        allocator.free(helper_json);\n    }" : ""}
    return .{
${assignments.join("\n")}
${extras.join("\n")}
        .raw = raw.take(),
        .arena = arena,
    };
}`;
}

function renderGeneratedPayload(entry) {
  return `pub const ${entry.payload} = OwnedPayload(${entry.dataDefinitionName}, wipe${entry.dataDefinitionName});`;
}

function renderUnion(entries) {
  return [
    ...entries.map((entry) => `    ${entry.tag}: ${entry.payload},`),
    "    unknown: payloads.UnknownEvent,",
  ].join("\n");
}

function renderKnownSwitch(entries, capture, expression) {
  return entries.map((entry) =>
    `            .${entry.tag} => ${capture ? `|${capture}| ` : ""}${expression(entry)},`
  ).join("\n");
}

function renderTagLookup(entries) {
  return entries.map((entry) =>
    `    if (std.mem.eql(u8, wire, ${zigString(entry.discriminator)})) return .${entry.tag};`
  ).join("\n");
}

function renderParseCases(entries) {
  return entries.map((entry) => {
    if (entry.rich) {
      return `        .${entry.tag} => return .{ .${entry.tag} = try ${entry.rich.parser}(allocator, data, &raw) },`;
    }
    return `        .${entry.tag} => {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const typed = try parse${entry.dataDefinitionName}(arena.allocator(), data_value);
            return .{ .${entry.tag} = .{
                .data = typed,
                .data_json = raw.takeData(),
                .arena = arena,
            } };
        },`;
  }).join("\n");
}

function renderRegistryEntries(entries) {
  return entries.map((entry) =>
    `    .{ .wire = ${zigString(entry.discriminator)}, .tag = .${entry.tag} },`
  ).join("\n");
}

function renderSamples(entries, schema) {
  return entries.map((entry) => {
    const json = JSON.stringify({
      type: entry.discriminator,
      data: minimalValue(schema.definitions[entry.dataDefinitionName], schema.definitions),
    });
    return `    .{ .json = ${zigString(json)}, .tag = .${entry.tag} },`;
  }).join("\n");
}

function renderMalformedSamples(entries, schema) {
  return entries.map((entry) => {
    const definition = schema.definitions[entry.dataDefinitionName];
    const required = definition.required ?? [];
    if (required.length === 0) return null;
    const data = minimalValue(definition, schema.definitions);
    delete data[required[0]];
    return `    ${zigString(JSON.stringify({ type: entry.discriminator, data }))},`;
  }).filter(Boolean).join("\n");
}

export function renderSessionEvents(schema) {
  const { entries, model } = buildRegistry(schema);
  const helpers = new Map();
  for (const [name, node] of model.nodes) collectHelpers(node, helpers, new Set());
  const typeModels = [...model.nodes.values()];
  const rich = entries.filter((entry) => entry.rich);
  const generated = entries.filter((entry) => !entry.rich);
  const permissionKinds = model.nodes.get("PermissionRequest").selection.values;

  const output = `const std = @import("std");
const payloads = @import("session_event_payloads.zig");

${typeModels.map(renderType).join("\n\n")}

fn OwnedPayload(comptime T: type, comptime wipe: fn (*T) void) type {
    return struct {
        data: T,
        data_json: []u8,
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            wipe(&self.data);
            self.arena.deinit();
            @memset(self.data_json, 0);
            allocator.free(self.data_json);
        }
    };
}

${generated.map(renderGeneratedPayload).join("\n")}

${rich.map(renderRichType).join("\n\n")}

pub const SessionEvent = union(enum) {
${renderUnion(entries)}

    pub fn eventType(self: SessionEvent) []const u8 {
        return switch (self) {
${renderKnownSwitch(entries, null, (entry) => zigString(entry.discriminator))}
            .unknown => |value| value.event_type,
        };
    }

    pub fn rawData(self: SessionEvent) []const u8 {
        return switch (self) {
${renderKnownSwitch(entries, "value", (entry) =>
    entry.rich ? "value.raw.data_json" : "value.data_json"
  )}
            .unknown => |value| value.data_json,
        };
    }

    pub fn deinit(self: *SessionEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
${renderKnownSwitch(entries, "*value", () => "value.deinit(allocator)")}
            .unknown => |*value| value.deinit(allocator),
        }
    }
};

pub const SessionEventTag = std.meta.Tag(SessionEvent);

pub const RegistryEntry = struct {
    wire: []const u8,
    tag: SessionEventTag,
};

pub const pinned_discriminators = [_]RegistryEntry{
${renderRegistryEntries(entries)}
};

fn valueString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => error.InvalidSessionEvent,
    };
}

fn parseString(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    minimum: ?usize,
    maximum: ?usize,
) ![]const u8 {
    const string = try valueString(value);
    const length = std.unicode.utf8CountCodepoints(string) catch
        return error.InvalidSessionEvent;
    if (minimum) |bound| if (length < bound) return error.InvalidSessionEvent;
    if (maximum) |bound| if (length > bound) return error.InvalidSessionEvent;
    return allocator.dupe(u8, string);
}

fn parseConstant(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    expected: []const u8,
) ![]const u8 {
    const string = try valueString(value);
    if (!std.mem.eql(u8, string, expected)) return error.InvalidSessionEvent;
    return allocator.dupe(u8, string);
}

fn parseBool(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.InvalidSessionEvent,
    };
}

fn parseInteger(
    comptime T: type,
    value: std.json.Value,
    minimum: ?i128,
    exclusive_minimum: ?i128,
    maximum: ?i128,
) !T {
    const integer: i128 = switch (value) {
        .integer => |number| number,
        .number_string => |number| std.fmt.parseInt(i128, number, 10) catch
            return error.InvalidSessionEvent,
        else => return error.InvalidSessionEvent,
    };
    if (minimum) |bound| if (integer < bound) return error.InvalidSessionEvent;
    if (exclusive_minimum) |bound| if (integer <= bound) return error.InvalidSessionEvent;
    if (maximum) |bound| if (integer > bound) return error.InvalidSessionEvent;
    return std.math.cast(T, integer) orelse error.InvalidSessionEvent;
}

fn parseNumber(
    value: std.json.Value,
    minimum: ?f64,
    exclusive_minimum: ?f64,
    maximum: ?f64,
) !f64 {
    const number: f64 = switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .number_string => |encoded| std.fmt.parseFloat(f64, encoded) catch
            return error.InvalidSessionEvent,
        else => return error.InvalidSessionEvent,
    };
    if (minimum) |bound| if (number < bound) return error.InvalidSessionEvent;
    if (exclusive_minimum) |bound| if (number <= bound) return error.InvalidSessionEvent;
    if (maximum) |bound| if (number > bound) return error.InvalidSessionEvent;
    return number;
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |boolean| .{ .bool = boolean },
        .integer => |integer| .{ .integer = integer },
        .float => |float| .{ .float = float },
        .number_string => |number| .{ .number_string = try allocator.dupe(u8, number) },
        .string => |string| .{ .string = try allocator.dupe(u8, string) },
        .array => |array| result: {
            var result = std.json.Array.init(allocator);
            errdefer for (result.items) |*item| wipeJsonValue(item);
            for (array.items) |item| {
                var cloned = try cloneJsonValue(allocator, item);
                errdefer wipeJsonValue(&cloned);
                try result.append(cloned);
            }
            break :result .{ .array = result };
        },
        .object => |object| result: {
            var result: std.json.ObjectMap = .empty;
            errdefer {
                var cleanup_iterator = result.iterator();
                while (cleanup_iterator.next()) |entry| {
                    wipeString(entry.key_ptr.*);
                    wipeJsonValue(entry.value_ptr);
                }
            }
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer wipeString(key);
                var cloned = try cloneJsonValue(allocator, entry.value_ptr.*);
                errdefer wipeJsonValue(&cloned);
                try result.put(allocator, key, cloned);
            }
            break :result .{ .object = result };
        },
    };
}

fn wipeString(value: []const u8) void {
    @memset(@constCast(value), 0);
}

fn wipeJsonValue(value: *std.json.Value) void {
    switch (value.*) {
        .number_string => |number| wipeString(number),
        .string => |string| wipeString(string),
        .array => |*array| for (array.items) |*item| wipeJsonValue(item),
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                wipeString(entry.key_ptr.*);
                wipeJsonValue(entry.value_ptr);
            }
        },
        else => {},
    }
}

fn freeJsonValue(value: *std.json.Value, allocator: std.mem.Allocator) void {
    switch (value.*) {
        .number_string => |number| {
            wipeString(number);
            allocator.free(@constCast(number));
        },
        .string => |string| {
            wipeString(string);
            allocator.free(@constCast(string));
        },
        .array => |*array| {
            for (array.items) |*item| freeJsonValue(item, allocator);
            array.deinit();
        },
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                wipeString(entry.key_ptr.*);
                allocator.free(@constCast(entry.key_ptr.*));
                freeJsonValue(entry.value_ptr, allocator);
            }
            object.deinit(allocator);
        },
        else => {},
    }
}

${[...helpers.values()].map(renderHelper).join("\n\n")}

${typeModels.map(renderParser).join("\n\n")}

${typeModels.map(renderWiper).join("\n\n")}

${typeModels.map(renderFreer).join("\n\n")}

${rich.map(renderRichFieldsWiper).join("\n\n")}

${rich.map(renderRichFieldsFreer).join("\n\n")}

fn isKnownPermissionRequestKind(kind: []const u8) bool {
${permissionKinds.map((kind) =>
    `    if (std.mem.eql(u8, kind, ${zigString(kind)})) return true;`
  ).join("\n")}
    return false;
}

fn managedApprovalRequired(data: std.json.ObjectMap) !bool {
    const request = data.get("permissionRequest") orelse return false;
    const object = try payloads.requiredObject(request);
    const value = object.get("managedApprovalRequired") orelse return false;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.InvalidSessionEvent,
    };
}

${rich.map(renderRichParser).join("\n\n")}

fn tagFromDiscriminator(wire: []const u8) ?SessionEventTag {
${renderTagLookup(entries)}
    return null;
}

pub fn parseEvent(allocator: std.mem.Allocator, value: std.json.Value) !SessionEvent {
    const object = try payloads.requiredObject(value);
    const wire = try payloads.requiredString(object, "type");
    const data_value: std.json.Value = object.get("data") orelse .{ .object = .empty };

    const tag = tagFromDiscriminator(wire) orelse {
        var raw = try payloads.ownRawData(allocator, data_value);
        errdefer raw.deinit(allocator);
        const owned_wire = try allocator.dupe(u8, wire);
        errdefer allocator.free(owned_wire);
        return .{ .unknown = .{
            .event_type = owned_wire,
            .data_json = raw.takeData(),
        } };
    };

    const data = try payloads.requiredObject(data_value);
    var raw = try payloads.ownRawData(allocator, data_value);
    errdefer raw.deinit(allocator);
    switch (tag) {
${renderParseCases(entries)}
        .unknown => unreachable,
    }
}

const EventSample = struct {
    json: []const u8,
    tag: SessionEventTag,
};

const pinned_event_samples = [_]EventSample{
${renderSamples(entries, schema)}
};

test "every pinned discriminator parses to its explicit tag" {
    const allocator = std.testing.allocator;
    for (pinned_event_samples) |sample| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, sample.json, .{});
        defer parsed.deinit();
        var event = try parseEvent(allocator, parsed.value);
        defer event.deinit(allocator);
        try std.testing.expectEqual(sample.tag, std.meta.activeTag(event));
        try std.testing.expectEqualStrings(sample.json[9 .. 9 + event.eventType().len], event.eventType());
    }
}

const malformed_event_samples = [_][]const u8{
${renderMalformedSamples(entries, schema)}
};

test "missing required fields fail for every generated payload" {
    const allocator = std.testing.allocator;
    for (malformed_event_samples) |sample| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, sample, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidSessionEvent, parseEvent(allocator, parsed.value));
    }
}
`;
  return formatZig(output);
}

export function generateSessionEvents({ check = false } = {}) {
  const schemaBytes = readFileSync(schemaPath);
  const schema = JSON.parse(schemaBytes);
  const expected = renderSessionEvents(schema);
  if (check) {
    const actual = readFileSync(outputPath, "utf8");
    if (actual !== expected) {
      throw new Error(
        "src/session_event_generated.zig is stale; run node scripts/generate-session-events.mjs",
      );
    }
  } else {
    writeFileSync(outputPath, expected);
  }
}

if (resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  if (args.length === 0) {
    generateSessionEvents();
  } else if (args.length === 1 && args[0] === "--check") {
    generateSessionEvents({ check: true });
  } else {
    throw new Error("usage: node scripts/generate-session-events.mjs [--check]");
  }
}
