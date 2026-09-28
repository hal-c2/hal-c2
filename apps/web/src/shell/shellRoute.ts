import { scopedThreadKey, scopeThreadRef } from "@hal-c2/client-runtime/environment";
import type { EnvironmentId, ThreadId } from "@hal-c2/contracts";
import type { ShellRoute } from "@hal-c2/contracts/shell";

import { resolveActiveSettingsSection } from "./shellSettingsState";

const EMPTY = { threadKey: null, draftId: null, projectKey: null, section: null } as const;

// First path segments that are routes of their own, not an environment id.
const RESERVED_SEGMENTS = new Set([
  "draft",
  "embed",
  "projects",
  "settings",
  "pair",
  "connect",
  "welcome",
  "pull-requests",
  "usage",
]);

/**
 * The shell route a page location shows, or null for the pages the shell has
 * no route for (pairing, onboarding, project pages, embeds).
 */
export function shellRouteFromPath(pathname: string): ShellRoute | null {
  const segments = pathname.split("/").filter((segment) => segment.length > 0);
  const [first, second] = segments.map((segment) => decodeURIComponent(segment));
  if (first === undefined) return { kind: "home", ...EMPTY };
  if (first === "settings") {
    return { kind: "settings", ...EMPTY, section: resolveActiveSettingsSection(pathname) };
  }
  if (segments.length === 1 && first === "pull-requests") return { kind: "pullRequests", ...EMPTY };
  if (segments.length === 1 && first === "usage") return { kind: "usage", ...EMPTY };
  if (segments.length !== 2 || second === undefined) return null;
  if (first === "draft") return { kind: "draft", ...EMPTY, draftId: second };
  if (RESERVED_SEGMENTS.has(first)) return null;
  const threadRef = scopeThreadRef(first as EnvironmentId, second as ThreadId);
  return { kind: "thread", ...EMPTY, threadKey: scopedThreadKey(threadRef) };
}

export function sameShellRoute(a: ShellRoute, b: ShellRoute): boolean {
  return (
    a.kind === b.kind &&
    a.threadKey === b.threadKey &&
    a.draftId === b.draftId &&
    a.projectKey === b.projectKey &&
    a.section === b.section
  );
}
