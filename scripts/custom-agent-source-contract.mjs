import {
  interfacePropertySignatures,
  requireExactPropertySignatures,
} from "./source-contract.mjs";

export function verifyCustomAgentConfigurationSourceContract(typesSource) {
  const actual = interfacePropertySignatures(typesSource, "CustomAgentConfig");
  requireExactPropertySignatures(actual, {
    name: "required:string",
    displayName: "optional:string",
    description: "optional:string",
    tools: "optional:string[]|null",
    prompt: "required:string",
    mcpServers: "optional:Record<string,MCPServerConfig>",
    infer: "optional:boolean",
    skills: "optional:string[]",
    model: "optional:string",
    reasoningEffort: "optional:ReasoningEffort",
    ...(Object.hasOwn(actual, "hooks")
      ? { hooks: "optional:Record<string,Record<string,unknown>[]>" }
      : {}),
  }, "CustomAgentConfig");
}
