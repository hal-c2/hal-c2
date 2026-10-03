import * as NodeFS from "node:fs";
import * as NodePath from "node:path";

/**
 * The threads whose alerts this device keeps quiet. The list is this
 * client's own: muting here does not mute the thread anywhere else.
 */
export interface MutedThreadsStore {
  readonly load: () => ReadonlyArray<string>;
  readonly save: (threadIds: ReadonlyArray<string>) => void;
}

export const MUTED_THREADS_FILE = "muted-threads.json";

/** Kept only while the client runs (the default, and what tests use). */
export function memoryMutedThreads(initial: ReadonlyArray<string> = []): MutedThreadsStore {
  let current = [...initial];
  return {
    load: () => current,
    save: (threadIds) => {
      current = [...threadIds];
    },
  };
}

/** Kept in a JSON file; a missing or unreadable file is an empty list. */
export function fileMutedThreads(path: string): MutedThreadsStore {
  return {
    load: () => {
      try {
        const parsed: unknown = JSON.parse(NodeFS.readFileSync(path, "utf8"));
        return Array.isArray(parsed) ? parsed.filter((id) => typeof id === "string") : [];
      } catch {
        return [];
      }
    },
    save: (threadIds) => {
      try {
        NodeFS.mkdirSync(NodePath.dirname(path), { recursive: true });
        NodeFS.writeFileSync(path, `${JSON.stringify(threadIds, null, 2)}\n`);
      } catch {
        // The mute still holds for this run.
      }
    },
  };
}
