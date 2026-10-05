import type {
  OrchestrationThreadActivity,
  ProviderApprovalDecision,
  ProviderApprovalOption,
} from "@hal-c2/contracts";

import { isStalePendingRequestFailureDetail } from "./staleRequest.ts";

export interface PendingApproval {
  readonly requestId: string;
  readonly requestKind: string;
  readonly detail?: string;
  readonly createdAt: string;
  /** The choices the provider offers; the default four when it names none. */
  readonly options: ReadonlyArray<ProviderApprovalOption>;
  /** The provider process that asked is gone: no answer can reach it. */
  readonly notResumable: boolean;
}

/** What the web's approval panel says when the request cannot be answered. */
export const PROVIDER_GONE = "Provider process is gone — interrupt or restart the run to respond.";

/** What the clients offer when the provider names no options, the primary one first. */
export const DEFAULT_APPROVAL_OPTIONS: ReadonlyArray<ProviderApprovalOption> = [
  { decision: "accept", label: "Approve" },
  { decision: "acceptForSession", label: "Always allow this session" },
  { decision: "decline", label: "Decline" },
  { decision: "cancel", label: "Cancel" },
] as ReadonlyArray<ProviderApprovalOption>;

const DECISIONS = new Set<string>([
  "accept",
  "acceptForSession",
  "acceptAlways",
  "decline",
  "cancel",
]);

/** What kind of permission a request wants (the web's ComposerPendingApprovalPanel titles). */
export function approvalTitle(requestKind: string): string {
  switch (requestKind) {
    case "command":
      return "Command approval";
    case "file-read":
      return "File read approval";
    case "mcp-elicitation":
      return "App access approval";
    case "permission":
      return "App permission approval";
    default:
      return "File change approval";
  }
}

/** The chord that answers with a decision, as the panel shows it. */
export function approvalKey(decision: ProviderApprovalDecision): string {
  switch (decision) {
    case "accept":
      return "^A";
    case "acceptForSession":
    case "acceptAlways":
      return "^S";
    case "decline":
      return "^R";
    case "cancel":
      return "^X";
  }
}

function parseOptions(value: unknown): ReadonlyArray<ProviderApprovalOption> {
  if (!Array.isArray(value)) return DEFAULT_APPROVAL_OPTIONS;
  const options: ProviderApprovalOption[] = [];
  for (const entry of value) {
    if (!entry || typeof entry !== "object") continue;
    const { decision, label, warning } = entry as Record<string, unknown>;
    if (typeof decision !== "string" || !DECISIONS.has(decision) || typeof label !== "string") {
      continue;
    }
    options.push({
      decision,
      label,
      ...(typeof warning === "string" && warning.trim().length > 0 ? { warning } : {}),
    } as ProviderApprovalOption);
  }
  return options.length > 0 ? options : DEFAULT_APPROVAL_OPTIONS;
}

/**
 * Derive the still-open approval requests for a thread from its activity log.
 * Mirrors the web client's logic: an `approval.requested` activity opens a
 * request, and a later `approval.resolved` (or stale-request failure) closes
 * it. Kept intentionally small — the TUI only needs requestId + a label.
 */
export function derivePendingApprovals(
  activities: ReadonlyArray<OrchestrationThreadActivity>,
): PendingApproval[] {
  const open = new Map<string, PendingApproval>();
  const ordered = [...activities].sort((a, b) => {
    const sa = a.sequence ?? -1;
    const sb = b.sequence ?? -1;
    if (sa !== sb) return sa - sb;
    return a.createdAt.localeCompare(b.createdAt);
  });

  for (const activity of ordered) {
    const payload =
      activity.payload && typeof activity.payload === "object"
        ? (activity.payload as Record<string, unknown>)
        : null;
    const requestId = payload && typeof payload.requestId === "string" ? payload.requestId : null;

    if (activity.kind === "approval.requested" && requestId) {
      const requestKind =
        payload && typeof payload.requestKind === "string" ? payload.requestKind : "approval";
      const detail = payload && typeof payload.detail === "string" ? payload.detail : undefined;
      open.set(requestId, {
        requestId,
        requestKind,
        createdAt: activity.createdAt,
        ...(detail ? { detail } : {}),
        options: parseOptions(payload?.options),
        notResumable: payload?.notResumable === true,
      });
      continue;
    }

    if (requestId && activity.kind === "approval.resolved") {
      open.delete(requestId);
      continue;
    }

    // A respond failure only closes the request when the provider reports it
    // stale/unknown — a transient failure (network blip) leaves it open so the
    // user can retry, matching the web derivation.
    if (requestId && activity.kind === "provider.approval.respond.failed") {
      const detail = payload && typeof payload.detail === "string" ? payload.detail : undefined;
      if (isStalePendingRequestFailureDetail(detail)) {
        open.delete(requestId);
      }
    }
  }

  return [...open.values()].sort((a, b) => a.createdAt.localeCompare(b.createdAt));
}
