/** The thread's terminal drawer on its own, for a secondary shell web view. */
export function buildTerminalEmbedPath(environmentId: string, threadId: string): string {
  return `/embed/${encodeURIComponent(environmentId)}/${encodeURIComponent(threadId)}?surface=terminal`;
}
