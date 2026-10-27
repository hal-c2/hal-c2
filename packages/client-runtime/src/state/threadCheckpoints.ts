import type {
  CheckpointId,
  CheckpointRef,
  CheckpointScopeId,
  MessageId,
  OrchestrationV2ThreadProjection,
  RunId,
} from "@hal-c2/contracts";
import * as DateTime from "effect/DateTime";

export interface ThreadCheckpointSummary {
  readonly checkpointId?: CheckpointId;
  readonly scopeId?: CheckpointScopeId;
  readonly runId: RunId;
  readonly checkpointTurnCount: number;
  readonly checkpointRef: CheckpointRef;
  readonly status: "ready" | "missing" | "error" | "stale";
  readonly files: ReadonlyArray<{
    readonly path: string;
    readonly kind: string;
    readonly additions: number;
    readonly deletions: number;
  }>;
  readonly assistantMessageId: MessageId | null;
  readonly completedAt: string;
}

/**
 * The checkpoints that count as diff turns, in run order: ready ones of
 * completed runs. A turn count is a position in this list, from 1 — how the
 * MC counts getTurnDiff/getFullThreadDiff turns, so rewound and unfinished
 * runs leave no gaps. A run the projection does not hold is not evidence
 * against a checkpoint. Shared by the summaries below and by
 * rollback-by-turn-count, so every surface numbers turns the same way.
 */
export function diffCheckpoints(projection: OrchestrationV2ThreadProjection) {
  const byId = new Map(projection.runs.map((run) => [run.id, run]));
  return projection.checkpoints
    .filter(
      (checkpoint) =>
        checkpoint.status === "ready" &&
        checkpoint.appRunOrdinal !== null &&
        checkpoint.runId !== null &&
        (byId.get(checkpoint.runId)?.status ?? "completed") === "completed",
    )
    .sort((left, right) => left.appRunOrdinal! - right.appRunOrdinal!);
}

/** Derives the checkpoint/diff rows needed by review UIs from native V2 entities. */
export function deriveThreadCheckpointSummaries(
  projection: OrchestrationV2ThreadProjection,
): ReadonlyArray<ThreadCheckpointSummary> {
  const turnOf = new Map(
    diffCheckpoints(projection).map((checkpoint, index) => [checkpoint.id, index + 1]),
  );
  return projection.checkpoints.flatMap((checkpoint) => {
    if (checkpoint.appRunOrdinal === null || checkpoint.runId === null) return [];
    const assistantMessageId =
      projection.messages.findLast(
        (message) => message.runId === checkpoint.runId && message.role === "assistant",
      )?.id ?? null;
    return [
      {
        checkpointId: checkpoint.id,
        scopeId: checkpoint.scopeId,
        runId: checkpoint.runId,
        // A checkpoint with no diff turn (not ready, or its run never
        // completed) keeps its run ordinal as a label; it is never asked
        // for a diff, and rollback refuses it as not ready.
        checkpointTurnCount: turnOf.get(checkpoint.id) ?? checkpoint.appRunOrdinal,
        checkpointRef: checkpoint.ref,
        status: checkpoint.status,
        files: checkpoint.files,
        assistantMessageId,
        completedAt: DateTime.formatIso(checkpoint.capturedAt),
      },
    ];
  });
}
