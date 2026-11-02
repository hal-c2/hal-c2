import * as Exit from "effect/Exit";
import * as Schema from "effect/Schema";

import {
  HalC2ProjectFile,
  HalC2ProjectFileSpaces,
  HAL_C2_PROJECT_FILE_SCHEMA_URL,
} from "@hal-c2/contracts";

import { fromLenientJson } from "./schemaJson.ts";

/**
 * Codec between the raw `hal-c2.json` file contents (lenient JSONC string) and the
 * decoded {@link HalC2ProjectFile}.
 */
export const HalC2ProjectFileFromJson = fromLenientJson(HalC2ProjectFile);

// The `spaces` section is read apart, as the MC reads it: one that does not match the
// format counts no files and leaves the rest of the file as it is.
const decodeHalC2ProjectFile = Schema.decodeExit(
  fromLenientJson(
    HalC2ProjectFile.mapFields((fields) => ({
      ...fields,
      spaces: Schema.optionalKey(Schema.Unknown),
    })),
  ),
);
const decodeSpaces = Schema.decodeUnknownExit(HalC2ProjectFileSpaces);

/**
 * Decode raw `hal-c2.json` contents, treating invalid or malformed files as
 * absent. Clients use this to read optional defaults (scripts, thread env
 * mode) without surfacing decode errors to the user. A `spaces` section that
 * does not match the format is left out.
 */
export function parseHalC2ProjectFile(contents: string): HalC2ProjectFile | null {
  const decoded = decodeHalC2ProjectFile(contents);
  if (!Exit.isSuccess(decoded)) return null;
  const { spaces, ...rest } = decoded.value;
  if (spaces === undefined) return rest;
  const section = decodeSpaces(spaces);
  return Exit.isSuccess(section) ? { ...rest, spaces: section.value } : rest;
}

/**
 * Build the publishable JSON Schema document for `hal-c2.json` (draft 2020-12).
 *
 * Served from the marketing site at {@link HAL_C2_PROJECT_FILE_SCHEMA_URL} so
 * editors get LSP support via a `$schema` reference.
 */
export function buildHalC2ProjectFileJsonSchema(): Record<string, unknown> {
  // Closed objects, as before effect rc.113 changed the generator default;
  // editors then flag unknown keys in hal-c2.json.
  const document = Schema.toJsonSchemaDocument(HalC2ProjectFile, { onExcessProperty: "error" });
  const jsonSchema: Record<string, unknown> = {
    $schema: "https://json-schema.org/draft/2020-12/schema",
    $id: HAL_C2_PROJECT_FILE_SCHEMA_URL,
    ...document.schema,
  };
  if (document.definitions && Object.keys(document.definitions).length > 0) {
    jsonSchema.$defs = document.definitions;
  }
  return jsonSchema;
}
