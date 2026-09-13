import assert from "node:assert/strict";
import test from "node:test";
import * as sourceContract from "./source-contract.mjs";
import {
  exportedStringUnionValues,
  inheritedInterfacePropertySignatures,
  interfacePropertySignatures,
  interfaceMemberSignatures,
  interfaceBase,
  omitIntersectionAlias,
  requireExactInterfaceSignatures,
  requireExactPropertySignatures,
  requireExactTypeImportBinding,
  requireSourceFragments,
  sourceSection,
  zigEnumValues,
  zigStructFields,
} from "./source-contract.mjs";

test("interface properties retain complete nested object types", () => {
  const source = `
export interface SessionFsConfig {
  initialCwd: string;
  capabilities?: {
    sqlite?: boolean;
    cache?: {
      enabled: boolean;
    };
  };
  conventions: "windows" | "posix";
}
`;

  assert.deepEqual(interfacePropertySignatures(source, "SessionFsConfig"), {
    initialCwd: "required:string",
    capabilities: "optional:{sqlite?:boolean;cache?:{enabled:boolean;};}",
    conventions: 'required:"windows"|"posix"',
  });
});

test("property separators inside strings and comments do not end a property", () => {
  const source = `
export interface Example {
  value: {
    literal: "};";
    /* }; */
    nested: { enabled: boolean; };
  };
  next: string;
}
`;

  assert.deepEqual(interfacePropertySignatures(source, "Example"), {
    value: 'required:{literal:"};";nested:{enabled:boolean;};}',
    next: "required:string",
  });
});

test("property parsing accepts complete interface declaration sections", () => {
  const source = `
export interface Example {
  first: string;
  nested?: {
    enabled: boolean;
  };
}
`;

  assert.deepEqual(interfacePropertySignatures(source, "Example"), {
    first: "required:string",
    nested: "optional:{enabled:boolean;}",
  });
});

test("unbalanced interface declarations are rejected", () => {
  assert.throws(
    () => interfacePropertySignatures(
      "export interface Broken { value: { nested: string; };",
      "Broken",
    ),
    /upstream Broken declaration has no matching }/,
  );
});

test("interface lookup ignores declarations in comments and strings", () => {
  const source = `
// export interface Example { lineComment: string; }
/* export interface Example { blockComment: string; } */
const quoted = "export interface Example { quoted: string; }";
const templated = \`export interface Example { templated: string; }\`;
export interface Example {
  actual: string;
}
`;

  assert.deepEqual(interfacePropertySignatures(source, "Example"), {
    actual: "required:string",
  });
});

test("interface property parsing rejects inherited properties", () => {
  const source = `
export interface Base {
  inherited: string;
}
export interface Example extends Base {
  direct: boolean;
}
`;

  assert.throws(
    () => interfacePropertySignatures(source, "Example"),
    /upstream Example must not use inheritance/,
  );
});

test("interface member parsing rejects inherited methods", () => {
  const source = `
export interface Base {
  inherited(): void;
}
export interface Example extends Base {
  direct(): boolean;
}
`;

  assert.throws(
    () => interfaceMemberSignatures(source, "Example"),
    /upstream Example must not use inheritance/,
  );
});

test("interface parsing rejects declaration merging", () => {
  const source = `
export interface Example {
  first: string;
}
export declare interface Example {
  second(): void;
}
`;

  for (const parse of [
    interfacePropertySignatures,
    interfaceMemberSignatures,
    interfaceBase,
  ]) {
    assert.throws(
      () => parse(source, "Example"),
      /upstream Example must have exactly one exported interface declaration/,
    );
  }
});

test("inherited interfaces return only their exact direct property set", () => {
  const source = `
export interface SessionConfigBase {
  inherited?: boolean;
}
export interface SessionConfig extends SessionConfigBase {
  sessionId?: string;
  cloud?: CloudSessionOptions;
}
`;

  assert.deepEqual(
    inheritedInterfacePropertySignatures(
      source,
      "SessionConfig",
      "SessionConfigBase",
    ),
    {
      sessionId: "optional:string",
      cloud: "optional:CloudSessionOptions",
    },
  );
  assert.throws(
    () => requireExactPropertySignatures(
      inheritedInterfacePropertySignatures(
        source.replace(
          "cloud?: CloudSessionOptions;",
          "cloud?: CloudSessionOptions;\n  added?: boolean;",
        ),
        "SessionConfig",
        "SessionConfigBase",
      ),
      {
        sessionId: "optional:string",
        cloud: "optional:CloudSessionOptions",
      },
      "SessionConfig",
    ),
    /SessionConfig fields changed/,
  );
});

test("inherited interfaces reject merging and unsupported bases", () => {
  assert.throws(
    () => inheritedInterfacePropertySignatures(
      `
export interface Example extends Base { direct?: string; }
export interface Example extends Base { merged?: boolean; }
`,
      "Example",
      "Base",
    ),
    /upstream Example must have exactly one exported interface declaration/,
  );
  assert.throws(
    () => inheritedInterfacePropertySignatures(
      "export interface Example extends Other { direct?: string; }",
      "Example",
      "Base",
    ),
    /upstream Example must extend exactly Base/,
  );
  assert.throws(
    () => inheritedInterfacePropertySignatures(
      "export interface Example extends Base, Other { direct?: string; }",
      "Example",
      "Base",
    ),
    /upstream Example must extend one simple base/,
  );
});

test("interface inheritance lookup ignores declarations in comments and strings", () => {
  const source = `
// export interface Example extends LineComment {}
/* export interface Example extends BlockComment {} */
const quoted = "export interface Example extends Quoted {}";
const templated = \`export interface Example extends Templated {}\`;
export interface Example extends SessionConfigBase {}
`;

  assert.equal(interfaceBase(source, "Example"), "SessionConfigBase");
});

test("exported string unions support comments, strings, and upstream formatting", () => {
  const source = `
// export type SessionFsSqliteQueryType = "wrong";
const quoted = 'export type SessionFsSqliteQueryType = "alsoWrong";';
export type SessionFsSqliteQueryType =
  | "exec"
  | "query" /* query rows */
  | 'run';
`;

  assert.deepEqual(
    exportedStringUnionValues(source, "SessionFsSqliteQueryType"),
    ["exec", "query", "run"],
  );
});

test("exported string unions reject merging, nonliterals, and duplicates", () => {
  assert.throws(
    () => exportedStringUnionValues(
      `
export type Example = "one";
export type Example = "two";
`,
      "Example",
    ),
    /upstream Example must have exactly one exported type alias declaration/,
  );
  assert.throws(
    () => exportedStringUnionValues(
      'export type Example = "one" | Other;',
      "Example",
    ),
    /upstream Example members must be string literals/,
  );
  assert.throws(
    () => exportedStringUnionValues(
      'export type Example = "one" | "one";',
      "Example",
    ),
    /upstream Example has duplicate value one/,
  );
});

test("exact string-union comparisons detect add, remove, and rename drift", () => {
  const expected = ["exec", "query", "run"];
  const declarations = {
    valid: 'export type QueryType = "exec" | "query" | "run";',
    add: 'export type QueryType = "exec" | "query" | "run" | "all";',
    remove: 'export type QueryType = "exec" | "query";',
    rename: 'export type QueryType = "exec" | "select" | "run";',
  };

  assert.deepEqual(
    exportedStringUnionValues(declarations.valid, "QueryType"),
    expected,
  );
  for (const category of ["add", "remove", "rename"]) {
    assert.throws(
      () => assert.deepEqual(
        exportedStringUnionValues(declarations[category], "QueryType"),
        expected,
      ),
      undefined,
      category,
    );
  }
});

test("named interfaces reject unsupported direct members", () => {
  for (const member of [
    "method(): void;",
    "[name: string]: unknown;",
    "(value: string): void;",
    "new (): Example;",
  ]) {
    assert.throws(
      () => interfacePropertySignatures(
        `export interface Example { value: string; ${member} }`,
        "Example",
      ),
      /unsupported property declaration/,
    );
  }
});

test("interface members retain complete method and property signatures", () => {
  const source = `
export interface SessionFsProvider {
  readFile(path: string): Promise<string>;
  writeFile(
    path: string,
    content: string,
    mode?: number
  ): Promise<void>;
  transaction?(
    statements: Array<{ query: string; params?: Record<string, number> }>
  ): Promise<{ rows: string[] }[]>;
  exists(): Promise<boolean>;
  sqlite?: SessionFsSqliteProvider;
}
`;

  assert.deepEqual(interfaceMemberSignatures(source, "SessionFsProvider"), {
    methods: {
      readFile: "required:(path:string)=>Promise<string>",
      writeFile:
        "required:(path:string,content:string,mode?:number)=>Promise<void>",
      transaction:
        "optional:(statements:Array<{query:string;params?:Record<string,number>}>)=>Promise<{rows:string[]}[]>",
      exists: "required:()=>Promise<boolean>",
    },
    properties: {
      sqlite: "optional:SessionFsSqliteProvider",
    },
  });
});

test("interface methods accept function-typed parameters", () => {
  const source = `
export interface Example {
  run(callback: (value: string) => void): Promise<void>;
}
`;

  assert.deepEqual(interfaceMemberSignatures(source, "Example"), {
    methods: {
      run: "required:(callback:(value:string)=>void)=>Promise<void>",
    },
    properties: {},
  });
});

test("exact interface contracts reject every signature drift category", () => {
  const expected = {
    methods: {
      writeFile:
        "required:(path:string,content:string,mode?:number)=>Promise<void>",
    },
    properties: {
      sqlite: "optional:SessionFsSqliteProvider",
    },
  };
  const declarations = {
    valid: `
export interface SessionFsProvider {
  writeFile(path: string, content: string, mode?: number): Promise<void>;
  sqlite?: SessionFsSqliteProvider;
}
`,
    add: `
export interface SessionFsProvider {
  writeFile(path: string, content: string, mode?: number): Promise<void>;
  exists(path: string): Promise<boolean>;
  sqlite?: SessionFsSqliteProvider;
}
`,
    remove: `
export interface SessionFsProvider {
  sqlite?: SessionFsSqliteProvider;
}
`,
    rename: `
export interface SessionFsProvider {
  writeFile(path: string, data: string, mode?: number): Promise<void>;
  sqlite?: SessionFsSqliteProvider;
}
`,
    type: `
export interface SessionFsProvider {
  writeFile(path: string, content: Uint8Array, mode?: number): Promise<boolean>;
  sqlite?: SessionFsSqliteProvider;
}
`,
    optionality: `
export interface SessionFsProvider {
  writeFile?(path: string, content: string, mode?: number): Promise<void>;
  sqlite?: SessionFsSqliteProvider;
}
`,
    parameterOptionality: `
export interface SessionFsProvider {
  writeFile(path: string, content: string, mode: number): Promise<void>;
  sqlite?: SessionFsSqliteProvider;
}
`,
    propertyOptionality: `
export interface SessionFsProvider {
  writeFile(path: string, content: string, mode?: number): Promise<void>;
  sqlite: SessionFsSqliteProvider;
}
`,
  };

  assert.equal(
    requireExactInterfaceSignatures(
      interfaceMemberSignatures(declarations.valid, "SessionFsProvider"),
      expected,
      "SessionFsProvider",
    ),
    undefined,
  );
  for (const category of [
    "add",
    "remove",
    "rename",
    "type",
    "optionality",
    "parameterOptionality",
    "propertyOptionality",
  ]) {
    assert.throws(
      () => requireExactInterfaceSignatures(
        interfaceMemberSignatures(
          declarations[category],
          "SessionFsProvider",
        ),
        expected,
        "SessionFsProvider",
      ),
      /SessionFsProvider/,
      category,
    );
  }
});

test("Zig enums require public visibility by default", () => {
  const source = `
pub const PublicMode = enum {
    one,
    two,
};

const PrivateMode = enum {
    three,
    four,
};
`;

  assert.deepEqual(zigEnumValues(source, "PublicMode"), ["one", "two"]);
  assert.deepEqual(
    zigEnumValues(source, "PublicMode", { visibility: "optional" }),
    ["one", "two"],
  );
  assert.throws(
    () => zigEnumValues(source, "PrivateMode"),
    /Zig PrivateMode declaration changed/,
  );
  assert.deepEqual(
    zigEnumValues(source, "PrivateMode", { visibility: "optional" }),
    ["three", "four"],
  );
});

test("Zig declaration lookup ignores comments and strings", () => {
  const source = `
// pub const Example = struct { comment: bool, };
/* pub const Mode = enum { block_comment, }; */
const quoted = "pub const Example = struct { quoted: bool, };";
const templated = \`pub const Mode = enum { templated, };\`;
pub const Example = struct { actual: bool = false, };
pub const Mode = enum { actual, };
`;

  assert.deepEqual(zigStructFields(source, "Example"), {
    actual: { type: "bool", default: "false" },
  });
  assert.deepEqual(zigEnumValues(source, "Mode"), ["actual"]);
});

test("Zig declaration lookup ignores multiline strings", () => {
  const source = String.raw`
const declarations =
    \\pub const Example = struct { multiline: bool, };
    \\pub const Mode = enum { multiline, };
pub const Example = struct { actual: bool = false, };
pub const Mode = enum { actual, };
`;

  assert.deepEqual(zigStructFields(source, "Example"), {
    actual: { type: "bool", default: "false" },
  });
  assert.deepEqual(zigEnumValues(source, "Mode"), ["actual"]);
});

test("Zig declaration lookup ignores nested declarations", () => {
  const source = `
pub const Container = struct {
    pub const Example = struct { nested: bool, };
    pub const Mode = enum { nested, };
};
pub const Example = struct { actual: bool = false, };
pub const Mode = enum { actual, };
`;

  assert.deepEqual(zigStructFields(source, "Example"), {
    actual: { type: "bool", default: "false" },
  });
  assert.deepEqual(zigEnumValues(source, "Mode"), ["actual"]);
});

test("Zig declaration lookup rejects duplicate top-level declarations", () => {
  assert.throws(
    () => zigStructFields(
      `
pub const Example = struct { first: bool, };
pub const Example = struct { second: bool, };
`,
      "Example",
    ),
    /exactly one/,
  );
  assert.throws(
    () => zigEnumValues(
      `
pub const Mode = enum { first, };
pub const Mode = enum { second, };
`,
      "Mode",
    ),
    /exactly one/,
  );
});

test("Omit intersection aliases retain the exact JoinSessionConfig shape", () => {
  const source = `
export type JoinSessionConfig = Omit<
  ResumeSessionConfig,
  "onPermissionRequest" | "extensionSdkPath"
> & {
  onPermissionRequest?: PermissionHandler;
  requestedEnvironmentVariables?: string[];
  factories?: FactoryHandle[];
};
`;

  assert.deepEqual(omitIntersectionAlias(source, "JoinSessionConfig"), {
    base: "ResumeSessionConfig",
    excluded: ["onPermissionRequest", "extensionSdkPath"],
    properties: {
      onPermissionRequest: "optional:PermissionHandler",
      requestedEnvironmentVariables: "optional:string[]",
      factories: "optional:FactoryHandle[]",
    },
  });
});

test("Omit alias lookup ignores comments and strings", () => {
  const source = `
// export type JoinSessionConfig = Omit<Wrong, "line"> & {};
/* export type JoinSessionConfig = Omit<Wrong, "block"> & {}; */
const quoted = 'export type JoinSessionConfig = Omit<Wrong, "quoted"> & {};';
const templated = \`export type JoinSessionConfig = Omit<Wrong, "templated"> & {};\`;
export type JoinSessionConfig = Omit<Base, "actual"> & {
  actual?: string;
};
`;

  assert.deepEqual(omitIntersectionAlias(source, "JoinSessionConfig"), {
    base: "Base",
    excluded: ["actual"],
    properties: {
      actual: "optional:string",
    },
  });
});

test("Omit intersection alias lookup ignores regex literals", () => {
  const source = String.raw`
const ratio = total / count;
const decoy = /export type JoinSessionConfig = Omit<Wrong, "regex"> & \{ escaped: [^/]; \}[;]/;
export type JoinSessionConfig = Omit<Base, "actual"> & {
  actual?: string;
};
`;

  assert.deepEqual(omitIntersectionAlias(source, "JoinSessionConfig"), {
    base: "Base",
    excluded: ["actual"],
    properties: {
      actual: "optional:string",
    },
  });
});

test("Omit intersection aliases handle comments and nested property types", () => {
  const source = `
export type JoinSessionConfig =
  Omit<
    ResumeSessionConfig,
    "onPermissionRequest" /* replaced below */ | "extensionSdkPath"
  > & {
    onPermissionRequest: (
      request: { nested: { value: "a;b" } },
    ) => Promise<"allow" | "deny">;
    metadata?: {
      values: Array<{ name: "two words"; enabled?: boolean }>;
    };
  };
`;

  assert.deepEqual(omitIntersectionAlias(source, "JoinSessionConfig"), {
    base: "ResumeSessionConfig",
    excluded: ["onPermissionRequest", "extensionSdkPath"],
    properties: {
      onPermissionRequest:
        'required:(request:{nested:{value:"a;b"}},)=>Promise<"allow"|"deny">',
      metadata:
        'optional:{values:Array<{name:"two words";enabled?:boolean}>;}',
    },
  });
});

test("Omit intersection aliases reject duplicate and nonliteral exclusions", () => {
  assert.throws(
    () => omitIntersectionAlias(
      'export type JoinSessionConfig = Omit<Base, "field" | "field"> & {};',
      "JoinSessionConfig",
    ),
    /duplicate exclusions/,
  );
  assert.throws(
    () => omitIntersectionAlias(
      'export type JoinSessionConfig = Omit<Base, keyof Other> & {};',
      "JoinSessionConfig",
    ),
    /exclusions must be string literals/,
  );
});

test("Omit intersection aliases reject extra intersections and trailing syntax", () => {
  assert.throws(
    () => omitIntersectionAlias(
      'export type JoinSessionConfig = Omit<Base, "field"> & {} & Other;',
      "JoinSessionConfig",
    ),
    /trailing syntax/,
  );
  assert.throws(
    () => omitIntersectionAlias(
      'export type JoinSessionConfig = Omit<Base, "field"> & {} trailing;',
      "JoinSessionConfig",
    ),
    /trailing syntax/,
  );
});

test("Omit intersection aliases preserve required and optional redeclarations", () => {
  const source = `
export type JoinSessionConfig = Omit<Base, "requiredField" | "optionalField"> & {
  requiredField: Handler;
  optionalField?: Handler;
};
`;

  assert.deepEqual(
    omitIntersectionAlias(source, "JoinSessionConfig").properties,
    {
      requiredField: "required:Handler",
      optionalField: "optional:Handler",
    },
  );
});

test("Omit intersection aliases reject duplicate properties", () => {
  assert.throws(
    () => omitIntersectionAlias(
      `
export type JoinSessionConfig = Omit<Base, "field"> & {
  field?: string;
  field: string;
};
`,
      "JoinSessionConfig",
    ),
    /duplicate property field/,
  );
});

test("plain Omit aliases retain one exact base and exclusion set", () => {
  const source = `
// export type SessionFsFileInfo = Omit<Wrong, "comment">;
const quoted = 'export type SessionFsFileInfo = Omit<Wrong, "string">;';
export type SessionFsFileInfo = Omit<
  SessionFsStatResult,
  "error"
>;
`;

  assert.deepEqual(
    sourceContract.plainOmitAlias(source, "SessionFsFileInfo"),
    {
      base: "SessionFsStatResult",
      excluded: ["error"],
    },
  );
});

test("plain Omit alias lookup ignores regex literals", () => {
  const source = String.raw`
const ratio = total / count;
if (enabled) /export type SessionFsFileInfo = Omit<Wrong, "regex">[;]\/escaped/.test(source);
export type SessionFsFileInfo = Omit<
  SessionFsStatResult,
  "error"
>;
`;

  assert.deepEqual(
    sourceContract.plainOmitAlias(source, "SessionFsFileInfo"),
    {
      base: "SessionFsStatResult",
      excluded: ["error"],
    },
  );
});

test("plain Omit aliases reject intersections and trailing syntax", () => {
  assert.throws(
    () => sourceContract.plainOmitAlias(
      'export type SessionFsFileInfo = Omit<SessionFsStatResult, "error"> & {};',
      "SessionFsFileInfo",
    ),
    /trailing syntax/,
  );
  assert.throws(
    () => sourceContract.plainOmitAlias(
      'export type SessionFsFileInfo = Omit<SessionFsStatResult, "error"> extra;',
      "SessionFsFileInfo",
    ),
    /trailing syntax/,
  );
});

test("type import provenance rejects duplicate matching bindings", () => {
  const binding = `
import type {
  SessionFsSqliteQueryResult as GeneratedSqliteQueryResult,
} from "./generated/rpc.js";
`;

  assert.throws(
    () => requireExactTypeImportBinding(
      `${binding}\n${binding}`,
      {
        imported: "SessionFsSqliteQueryResult",
        local: "GeneratedSqliteQueryResult",
        module: "./generated/rpc.js",
      },
      "SQLite result import",
    ),
    /exactly one relevant type import binding/,
  );
});

test("type import provenance rejects unsupported relevant import syntax", () => {
  const expected = {
    imported: "SessionFsSqliteQueryResult",
    local: "GeneratedSqliteQueryResult",
    module: "./generated/rpc.js",
  };
  for (const source of [
    `import {
      type SessionFsSqliteQueryResult as GeneratedSqliteQueryResult,
    } from "./generated/rpc.js";`,
    `import {
      SessionFsSqliteQueryResult as GeneratedSqliteQueryResult,
    } from "./generated/rpc.js";`,
    `import type GeneratedSqliteQueryResult from "./generated/rpc.js";`,
    `import type * as GeneratedSqliteQueryResult from "./generated/rpc.js";`,
    `import type {
      SessionFsSqliteQueryResult as GeneratedSqliteQueryResult,
    } from "./generated/rpc.js" with { type: "json" };`,
    `import type {
      , SessionFsSqliteQueryResult as GeneratedSqliteQueryResult
    } from "./generated/rpc.js";`,
    `import type {
      SessionFsSqliteQueryResult as GeneratedSqliteQueryResult,,
    } from "./generated/rpc.js";`,
  ]) {
    assert.throws(
      () => requireExactTypeImportBinding(
        source,
        expected,
        "SQLite result import",
      ),
      /unsupported import syntax/,
    );
  }
});

test("type import provenance ignores lexical decoys and unrelated import syntax", () => {
  const source = `
const pattern = /import type { SessionFsSqliteQueryResult as GeneratedSqliteQueryResult } from ".\\/wrong.js"/;
import type { "external" as External } from "./other.js";
import type {
  SessionFsSqliteQueryResult as GeneratedSqliteQueryResult,
} from "./generated/rpc.js";
`;

  assert.equal(
    requireExactTypeImportBinding(
      source,
      {
        imported: "SessionFsSqliteQueryResult",
        local: "GeneratedSqliteQueryResult",
        module: "./generated/rpc.js",
      },
      "SQLite result import",
    ),
    undefined,
  );
});

test("Zig structs return normalized types and explicit normalized defaults", () => {
  const source = `
pub const Example = struct {
    bytes: []const u8,
    nested: ?[]const []const u8 = null,
    provider: provider.ProviderConfig = .{},
    callback: *const fn (
        value: []const u8,
        context: ?*anyopaque,
    ) anyerror!void,
    configured: struct {
        values: []const u8,
    } = .{ .values = "a,b" },
};
`;

  assert.deepEqual(zigStructFields(source, "Example"), {
    bytes: { type: "[]const u8", default: null },
    nested: { type: "?[]const[]const u8", default: "null" },
    provider: { type: "provider.ProviderConfig", default: ".{}" },
    callback: {
      type: "*const fn(value:[]const u8,context:?*anyopaque,)anyerror!void",
      default: null,
    },
    configured: {
      type: "struct{values:[]const u8,}",
      default: '.{.values="a,b"}',
    },
  });
});

test("Zig structs handle comments without merging type tokens", () => {
  const source = `
pub const Example = struct {
    bytes: []const /* element */ u8 = &.{},
    callback: *const fn () void,
};
`;

  assert.deepEqual(zigStructFields(source, "Example"), {
    bytes: { type: "[]const u8", default: "&.{}" },
    callback: { type: "*const fn()void", default: null },
  });
});

test("Zig struct defaults preserve absence, null, booleans, and literals", () => {
  const source = `
pub const Example = struct {
    absent: ?bool,
    nullable: ?bool = null,
    enabled: bool = true,
    disabled: bool = false,
    label: []const u8 = "a b",
};
`;

  assert.deepEqual(zigStructFields(source, "Example"), {
    absent: { type: "?bool", default: null },
    nullable: { type: "?bool", default: "null" },
    enabled: { type: "bool", default: "true" },
    disabled: { type: "bool", default: "false" },
    label: { type: "[]const u8", default: '"a b"' },
  });
});

test("exact Zig field contracts reject default drift", () => {
  const expected = {
    optional: { type: "?bool", default: "null" },
    suppress_resume_event: { type: "bool", default: "false" },
  };

  assert.equal(
    requireExactPropertySignatures(
      zigStructFields(
        `
pub const Example = struct {
    optional: ?bool = null,
    suppress_resume_event: bool = false,
};
`,
        "Example",
      ),
      expected,
      "Zig Example",
    ),
    undefined,
  );
  assert.throws(
    () => requireExactPropertySignatures(
      zigStructFields(
        `
pub const Example = struct {
    optional: ?bool,
    suppress_resume_event: bool = true,
};
`,
        "Example",
      ),
      expected,
      "Zig Example",
    ),
    /Zig Example\.(optional|suppress_resume_event) changed/,
  );
});

test("Zig structs reject duplicate fields and malformed delimiters", () => {
  assert.throws(
    () => zigStructFields(
      "pub const Example = struct { value: bool, value: ?bool = null, };",
      "Example",
    ),
    /duplicate field value/,
  );
  assert.throws(
    () => zigStructFields(
      "pub const Example = struct { value: []const [u8, };",
      "Example",
    ),
    /mismatched delimiters|no matching/,
  );
  assert.throws(
    () => zigStructFields(
      "pub const Example = struct { value: bool = , };",
      "Example",
    ),
    /empty default/,
  );
});

test("exact interface contracts reject added and removed direct fields", () => {
  const expected = {
    shared: "optional:string",
    runtime: "optional:boolean",
  };

  assert.deepEqual(
    requireExactPropertySignatures(
      interfacePropertySignatures(
        "export interface SessionConfigBase { shared?: string; runtime?: boolean; }",
        "SessionConfigBase",
      ),
      expected,
      "SessionConfigBase",
    ),
    undefined,
  );
  assert.throws(
    () => requireExactPropertySignatures(
      interfacePropertySignatures(
        "export interface SessionConfigBase { shared?: string; runtime?: boolean; added?: number; }",
        "SessionConfigBase",
      ),
      expected,
      "SessionConfigBase",
    ),
    /SessionConfigBase fields changed/,
  );
  assert.throws(
    () => requireExactPropertySignatures(
      interfacePropertySignatures(
        "export interface SessionConfigBase { shared?: string; }",
        "SessionConfigBase",
      ),
      expected,
      "SessionConfigBase",
    ),
    /SessionConfigBase fields changed/,
  );
});

test("source sections ignore markers in comments and strings", () => {
  const source = `
// START fake line END
/* START fake block END */
const quoted = "START fake quoted END";
const templated = \`START fake templated END\`;
START
const actual = true;
END
`;

  assert.equal(
    sourceSection(source, "START", "END", "Example"),
    "START\nconst actual = true;\n",
  );
  assert.throws(
    () => sourceSection(
      'const text = "ONLY_START"; // ONLY_END',
      "ONLY_START",
      "ONLY_END",
      "Example",
    ),
    /declaration is missing/,
  );
});

test("required source fragments ignore comments and strings", () => {
  const decoys = `
// clientName: config.clientName
/* .clientName = options.client_name */
const quoted = "customAgents: toWireCustomAgents(config.customAgents)";
const templated = \`if (!agents) return undefined\`;
`;

  for (const fragment of [
    "clientName: config.clientName",
    ".clientName = options.client_name",
    "customAgents: toWireCustomAgents(config.customAgents)",
    "if (!agents) return undefined",
  ]) {
    assert.throws(
      () => requireSourceFragments(decoys, [fragment], "lowering"),
      /declaration is missing/,
    );
  }

  assert.equal(
    requireSourceFragments(
      'const mode = "fast";\nreturn { mode: "fast" };',
      ['return { mode: "fast" }'],
      "lowering",
    ),
    undefined,
  );
});
