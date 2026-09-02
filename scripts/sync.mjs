import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repository = "github/copilot-sdk";
const ref = "main";
const schemaNames = ["api.schema.json", "session-events.schema.json"];
const root = dirname(dirname(fileURLToPath(import.meta.url)));
const vendorDirectory = join(root, "vendor", "copilot");
const schemaDirectory = join(vendorDirectory, "schemas");
const metadataPath = join(vendorDirectory, "upstream.json");
const generatedPath = join(root, "src", "protocol_version.zig");
const compatibilityPath = join(root, "sync", "compatibility.json");
const workDirectory = join(root, ".sync-work");

function parseJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function digest(bytes) {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function validateMetadata(metadata) {
  const expectedKeys = [
    "cliPackageVersion",
    "schemaDigests",
    "sdkProtocolVersion",
    "upstreamCommit",
    "upstreamRef",
    "upstreamRepository",
  ];
  assert(Object.keys(metadata).sort().join(",") === expectedKeys.join(","), "metadata fields are invalid");
  assert(metadata.upstreamRepository === repository, "metadata repository is invalid");
  assert(metadata.upstreamRef === ref, "metadata ref is invalid");
  assert(/^[0-9a-f]{40}$/.test(metadata.upstreamCommit), "metadata commit is invalid");
  assert(Number.isSafeInteger(metadata.sdkProtocolVersion) && metadata.sdkProtocolVersion >= 0, "metadata protocol version is invalid");
  assert(/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(metadata.cliPackageVersion), "metadata CLI package version is invalid");
  assert(metadata.schemaDigests && Object.keys(metadata.schemaDigests).sort().join(",") === schemaNames.sort().join(","), "metadata schema digests are invalid");
  for (const name of schemaNames) {
    assert(/^sha256:[0-9a-f]{64}$/.test(metadata.schemaDigests[name]), `metadata digest for ${name} is invalid`);
  }
}

function collectPropertyValues(value, property, output = new Set()) {
  if (Array.isArray(value)) {
    for (const item of value) collectPropertyValues(item, property, output);
  } else if (value && typeof value === "object") {
    if (typeof value[property] === "string") output.add(value[property]);
    for (const item of Object.values(value)) collectPropertyValues(item, property, output);
  }
  return output;
}

function eventDiscriminators(schema) {
  const values = new Set();
  for (const definition of Object.values(schema.definitions ?? {})) {
    const discriminator = definition?.properties?.type?.const;
    if (typeof discriminator === "string") values.add(discriminator);
  }
  return values;
}

function verifyCompatibility(apiSchema, eventSchema) {
  const compatibility = parseJson(compatibilityPath);
  assert(Array.isArray(compatibility.wireMethods), "wireMethods must be an array");
  assert(Array.isArray(compatibility.sessionEventDiscriminators), "sessionEventDiscriminators must be an array");

  const methods = collectPropertyValues(apiSchema, "rpcMethod");
  const clientSource = readFileSync(join(root, "src", "client.zig"), "utf8");
  for (const method of compatibility.wireMethods) {
    assert(typeof method.name === "string", "wire method name is invalid");
    if (method.declaredBy === "api.schema.json") {
      assert(methods.has(method.name), `required schema RPC method is missing: ${method.name}`);
    } else if (method.declaredBy === "src/client.zig") {
      assert(clientSource.includes(`"${method.name}"`), `required SDK wire method is missing: ${method.name}`);
    } else {
      throw new Error(`unsupported wire method source: ${method.declaredBy}`);
    }
  }

  const discriminators = eventDiscriminators(eventSchema);
  for (const discriminator of compatibility.sessionEventDiscriminators) {
    assert(discriminators.has(discriminator), `required session event is missing: ${discriminator}`);
  }
}

function verify() {
  const metadata = parseJson(metadataPath);
  validateMetadata(metadata);
  const schemas = {};

  for (const name of schemaNames) {
    const path = join(schemaDirectory, name);
    const bytes = readFileSync(path);
    assert(digest(bytes) === metadata.schemaDigests[name], `${name} does not match its recorded digest`);
    schemas[name] = JSON.parse(bytes);
  }

  const expectedGenerated = `pub const sdk_protocol_version: u64 = ${metadata.sdkProtocolVersion};\n`;
  assert(readFileSync(generatedPath, "utf8") === expectedGenerated, "generated Zig protocol version is stale");
  verifyCompatibility(schemas["api.schema.json"], schemas["session-events.schema.json"]);
  console.log(`Verified ${metadata.upstreamCommit} with @github/copilot ${metadata.cliPackageVersion}`);
}

function requestHeaders() {
  const headers = {
    Accept: "application/vnd.github+json",
    "User-Agent": "copilot-sdk-zig-sync",
  };
  if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  return headers;
}

async function fetchJson(url) {
  const response = await fetch(url, { headers: requestHeaders() });
  if (!response.ok) throw new Error(`request failed with ${response.status}: ${url}`);
  return response.json();
}

async function resolveCommit(explicitCommit) {
  if (explicitCommit) {
    assert(/^[0-9a-f]{40}$/.test(explicitCommit), "--commit requires a 40-character lowercase SHA");
    return explicitCommit;
  }
  const commit = await fetchJson(`https://api.github.com/repos/${repository}/commits/${ref}`);
  assert(/^[0-9a-f]{40}$/.test(commit.sha), "GitHub returned an invalid commit SHA");
  return commit.sha;
}

function rawUrl(commit, path) {
  return `https://raw.githubusercontent.com/${repository}/${commit}/${path}`;
}

function findSchemaSource() {
  const scopeDirectory = join(workDirectory, "node_modules", "@github");
  for (const entry of readdirSync(scopeDirectory).sort()) {
    const candidate = join(scopeDirectory, entry, "schemas");
    if (schemaNames.every((name) => existsSync(join(candidate, name)))) return candidate;
  }
  throw new Error("installed @github/copilot package does not contain the required schemas");
}

function installSchemaPackage(version, ifPublished) {
  rmSync(workDirectory, { force: true, recursive: true });
  mkdirSync(workDirectory, { recursive: true });
  try {
    execFileSync(
      "npm",
      [
        "install",
        "--prefix",
        workDirectory,
        "--no-save",
        "--package-lock=false",
        "--ignore-scripts",
        "--allow-remote=all",
        `@github/copilot@${version}`,
      ],
      { stdio: ifPublished ? "pipe" : "inherit" },
    );
  } catch (error) {
    const stderr = String(error.stderr);
    if (ifPublished && (stderr.includes("E404") || stderr.includes("ETARGET"))) {
      console.log(`Deferred sync because @github/copilot ${version} is not published`);
      return null;
    }
    throw error;
  }
  return findSchemaSource();
}

async function synchronize(explicitCommit, ifPublished = false) {
  const commit = await resolveCommit(explicitCommit);
  const [protocol, lock] = await Promise.all([
    fetchJson(rawUrl(commit, "sdk-protocol-version.json")),
    fetchJson(rawUrl(commit, "nodejs/package-lock.json")),
  ]);
  const cliPackage = lock.packages?.["node_modules/@github/copilot"];
  assert(Number.isSafeInteger(protocol.version), "upstream protocol version is invalid");
  assert(/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(cliPackage?.version), "upstream lockfile has no exact @github/copilot version");

  try {
    const sourceDirectory = installSchemaPackage(cliPackage.version, ifPublished);
    if (sourceDirectory === null) return;
    mkdirSync(schemaDirectory, { recursive: true });
    const schemaDigests = {};
    for (const name of schemaNames) {
      const destination = join(schemaDirectory, name);
      cpSync(join(sourceDirectory, name), destination);
      schemaDigests[name] = digest(readFileSync(destination));
    }

    const metadata = {
      upstreamRepository: repository,
      upstreamRef: ref,
      upstreamCommit: commit,
      sdkProtocolVersion: protocol.version,
      cliPackageVersion: cliPackage.version,
      schemaDigests,
    };
    validateMetadata(metadata);
    writeFileSync(metadataPath, `${JSON.stringify(metadata, null, 2)}\n`);
    writeFileSync(generatedPath, `pub const sdk_protocol_version: u64 = ${protocol.version};\n`);
  } finally {
    rmSync(workDirectory, { force: true, recursive: true });
  }

  verify();
}

const args = process.argv.slice(2);
if (args.includes("--check")) {
  assert(args.length === 1, "--check does not accept other arguments");
  verify();
} else {
  const commitIndex = args.indexOf("--commit");
  const explicitCommit = commitIndex === -1 ? undefined : args[commitIndex + 1];
  const ifPublished = args.length === 1 && args[0] === "--if-published";
  assert(ifPublished || args.length === (explicitCommit ? 2 : 0), "usage: npm run sync -- [--commit <sha> | --if-published]");
  await synchronize(explicitCommit, ifPublished);
}
