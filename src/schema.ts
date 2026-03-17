import { z, type ZodTypeAny } from "zod";
import type { ToolInputSchema } from "./types.js";

export const MCP_RESPONSE_MODE_PARAM = "__mcp_response_mode";
const MCP_RESPONSE_MODES = ["content", "structuredContent"] as const;
const MCP_RESPONSE_MODE_TSDOC = `@param ${MCP_RESPONSE_MODE_PARAM} Optional response mode: content (default) or structuredContent.`;

export function appendResponseModeParamDoc(description: string): string {
  if (description.includes(`@param ${MCP_RESPONSE_MODE_PARAM}`)) {
    return description;
  }
  return `${description}\n${MCP_RESPONSE_MODE_TSDOC}`;
}

export function buildInputSchema(input: ToolInputSchema): ZodTypeAny {
  const properties = input.properties ?? {};
  const required = new Set(input.required ?? []);
  const shape: Record<string, ZodTypeAny> = {};

  for (const [name, prop] of Object.entries(properties)) {
    let schema: ZodTypeAny;
    switch (prop.type) {
      case "string":
        schema = z.string();
        break;
      case "number":
        schema = z.number();
        break;
      case "integer":
        schema = z.number().int();
        break;
      case "boolean":
        schema = z.boolean();
        break;
      default:
        throw new Error(`Unsupported input type '${String(prop.type)}' for '${name}'`);
    }

    shape[name] = required.has(name) ? schema : schema.optional();
  }

  shape[MCP_RESPONSE_MODE_PARAM] = z.enum(MCP_RESPONSE_MODES).optional().default("content");

  return z.object(shape);
}
