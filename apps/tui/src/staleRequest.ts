/**
 * Whether a `provider.*.respond.failed` activity's detail marks the underlying
 * request as stale/unknown — the only failure class that should CLOSE a pending
 * approval / user-input prompt. Any other failure (network blip, provider
 * hiccup) leaves the request open so the user can retry.
 */
export function isStalePendingRequestFailureDetail(detail: string | undefined): boolean {
  const normalized = detail?.toLowerCase();
  if (!normalized) {
    return false;
  }
  return (
    normalized.includes("stale pending approval request") ||
    normalized.includes("stale pending user-input request") ||
    normalized.includes("unknown pending approval request") ||
    normalized.includes("unknown pending permission request") ||
    normalized.includes("unknown pending user-input request") ||
    normalized.includes("unknown pending user input request") ||
    normalized.includes("unknown pending codex user input request")
  );
}
