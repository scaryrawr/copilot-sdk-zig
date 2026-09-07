import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const schemaDirectory = join(root, "vendor", "copilot", "schemas");
const snapshotPath = join(root, "sync", "schema-snapshot.json");

function parseSchema(name) {
  return JSON.parse(readFileSync(join(schemaDirectory, name), "utf8"));
}

function collectStrings(value, property, output = new Set()) {
  if (Array.isArray(value)) {
    for (const item of value) collectStrings(item, property, output);
  } else if (value && typeof value === "object") {
    if (typeof value[property] === "string") output.add(value[property]);
    for (const item of Object.values(value)) collectStrings(item, property, output);
  }
  return output;
}

function sortedStrings(values) {
  return [...values].sort();
}

function definition(schema, name) {
  const value = schema.definitions?.[name];
  if (!value) throw new Error(`missing schema definition: ${name}`);
  return value;
}

export function schemaContract(value) {
  if (typeof value?.$ref === "string") {
    return { ref: value.$ref.split("/").at(-1) };
  }
  if (typeof value?.type !== "string") {
    throw new Error("schema value has no type or reference");
  }

  const contract = { type: value.type };
  if (value.additionalProperties !== undefined) {
    contract.additionalProperties =
      value.additionalProperties === true || value.additionalProperties === false
        ? value.additionalProperties
        : schemaContract(value.additionalProperties);
  }
  return contract;
}

function propertyContracts(value, name) {
  if (!value.properties) throw new Error(`${name} has no properties`);
  return Object.fromEntries(
    Object.entries(value.properties)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([property, schema]) => [property, schemaContract(schema)]),
  );
}

function enumValues(schema, name) {
  const values = definition(schema, name).enum;
  if (!Array.isArray(values) || values.some((value) => typeof value !== "string")) {
    throw new Error(`${name} has no string enum`);
  }
  return [...values].sort();
}

function sessionEventDiscriminators(schema) {
  const sessionEvent = definition(schema, "SessionEvent");
  if (!Array.isArray(sessionEvent.anyOf)) {
    throw new Error("SessionEvent has no anyOf variants");
  }

  return sortedStrings(
    sessionEvent.anyOf.map((variant) => {
      if (typeof variant.$ref !== "string") {
        throw new Error("SessionEvent variant has no reference");
      }
      const eventName = variant.$ref.split("/").at(-1);
      const discriminator = definition(schema, eventName)?.properties?.type?.const;
      if (typeof discriminator !== "string") {
        throw new Error(`${eventName} has no string type discriminator`);
      }
      return discriminator;
    }),
  );
}

function rpcMethodsForScope(schema, scope) {
  const value = schema[scope];
  if (!value || typeof value !== "object") {
    throw new Error(`missing RPC scope: ${scope}`);
  }
  return sortedStrings(collectStrings(value, "rpcMethod"));
}

export function buildSchemaSnapshot() {
  const apiSchema = parseSchema("api.schema.json");
  const eventSchema = parseSchema("session-events.schema.json");
  const provider = definition(apiSchema, "ProviderConfig");

  return {
    rpcMethods: sortedStrings(collectStrings(apiSchema, "rpcMethod")),
    rpcScopes: {
      outboundGlobal: rpcMethodsForScope(apiSchema, "server"),
      outboundSession: rpcMethodsForScope(apiSchema, "session"),
      inboundGlobal: rpcMethodsForScope(apiSchema, "clientGlobal"),
      inboundSession: rpcMethodsForScope(apiSchema, "clientSession"),
    },
    sessionEventDiscriminators: sessionEventDiscriminators(eventSchema),
    providerConfig: {
      properties: propertyContracts(provider, "ProviderConfig"),
      required: sortedStrings(provider.required ?? []),
      families: enumValues(apiSchema, "ProviderConfigType"),
      wireApis: enumValues(apiSchema, "ProviderConfigWireApi"),
      transports: enumValues(apiSchema, "ProviderConfigTransport"),
      azureProperties: propertyContracts(
        definition(apiSchema, "ProviderConfigAzure"),
        "ProviderConfigAzure",
      ),
    },
  };
}

export function schemaSnapshotText() {
  return `${JSON.stringify(buildSchemaSnapshot(), null, 2)}\n`;
}

export function writeSchemaSnapshot() {
  writeFileSync(snapshotPath, schemaSnapshotText());
}

export function checkSchemaSnapshot() {
  const expected = schemaSnapshotText();
  const actual = readFileSync(snapshotPath, "utf8");
  if (actual !== expected) {
    throw new Error("sync/schema-snapshot.json is stale; run npm run sync");
  }
}

if (resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  if (args.length === 0) {
    writeSchemaSnapshot();
  } else if (args.length === 1 && args[0] === "--check") {
    checkSchemaSnapshot();
  } else {
    throw new Error("usage: node scripts/schema-snapshot.mjs [--check]");
  }
}
