import * as Exit from "effect/Exit";
import * as Schema from "effect/Schema";

import { HalC2ProjectFile, HALC2_PROJECT_FILE_SCHEMA_URL } from "@hal-c2/contracts";

import { fromLenientJson } from "./schemaJson.ts";

/**
 * Codec between the raw `hal-c2.json` file contents (lenient JSONC string) and the
 * decoded {@link HalC2ProjectFile}.
 */
export const HalC2ProjectFileFromJson = fromLenientJson(HalC2ProjectFile);

const decodeHalC2ProjectFile = Schema.decodeExit(HalC2ProjectFileFromJson);

/**
 * Decode raw `hal-c2.json` contents, treating invalid or malformed files as
 * absent. Clients use this to read optional defaults (scripts, thread env
 * mode) without surfacing decode errors to the user.
 */
export function parseHalC2ProjectFile(contents: string): HalC2ProjectFile | null {
  const decoded = decodeHalC2ProjectFile(contents);
  return Exit.isSuccess(decoded) ? decoded.value : null;
}

/**
 * Build the publishable JSON Schema document for `hal-c2.json` (draft 2020-12).
 *
 * Served from the marketing site at {@link HALC2_PROJECT_FILE_SCHEMA_URL} so
 * editors get LSP support via a `$schema` reference.
 */
export function buildHalC2ProjectFileJsonSchema(): Record<string, unknown> {
  // Closed objects, as before effect rc.113 changed the generator default;
  // editors then flag unknown keys in hal-c2.json.
  const document = Schema.toJsonSchemaDocument(HalC2ProjectFile, { onExcessProperty: "error" });
  const jsonSchema: Record<string, unknown> = {
    $schema: "https://json-schema.org/draft/2020-12/schema",
    $id: HALC2_PROJECT_FILE_SCHEMA_URL,
    ...document.schema,
  };
  if (document.definitions && Object.keys(document.definitions).length > 0) {
    jsonSchema.$defs = document.definitions;
  }
  return jsonSchema;
}
