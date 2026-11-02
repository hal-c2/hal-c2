import * as NodeFS from "node:fs";
import * as NodePath from "node:path";

import { TIMESTAMP_FORMATS, type TimestampFormat } from "../timestampFormat.ts";

/** How this device writes the times messages were sent; the other clients' setting of the same name. */
export interface TimestampFormatStore {
  readonly load: () => TimestampFormat;
  readonly save: (format: TimestampFormat) => void;
}

export const TIMESTAMP_FORMAT_FILE = "timestamp-format.json";

/** Kept only while the client runs (the default, and what tests use). */
export function memoryTimestampFormat(initial: TimestampFormat = "locale"): TimestampFormatStore {
  let current = initial;
  return {
    load: () => current,
    save: (format) => {
      current = format;
    },
  };
}

/** Kept in a JSON file; a missing or unreadable one is the locale's format. */
export function fileTimestampFormat(path: string): TimestampFormatStore {
  return {
    load: () => {
      try {
        const parsed: unknown = JSON.parse(NodeFS.readFileSync(path, "utf8"));
        return TIMESTAMP_FORMATS.find((format) => format === parsed) ?? "locale";
      } catch {
        return "locale";
      }
    },
    save: (format) => {
      try {
        NodeFS.mkdirSync(NodePath.dirname(path), { recursive: true });
        NodeFS.writeFileSync(path, `${JSON.stringify(format)}\n`);
      } catch {
        // The format still holds for this run.
      }
    },
  };
}
