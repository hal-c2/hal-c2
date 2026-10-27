import {
  CheckpointId,
  CheckpointRef,
  CheckpointScopeId,
  MessageId,
  NodeId,
  RunId,
  type OrchestrationV2Checkpoint,
  type OrchestrationV2Run,
  type OrchestrationV2ThreadProjection,
} from "@hal-c2/contracts";
import { describe, expect, it } from "@effect/vitest";

import { v2Now, v2Projection, v2ThreadId } from "./orchestrationV2TestFixtures.ts";
import { deriveThreadCheckpointSummaries, diffCheckpoints } from "./threadCheckpoints.ts";

function run(ordinal: number, status: OrchestrationV2Run["status"]): OrchestrationV2Run {
  return {
    id: RunId.make(`run-${ordinal}`),
    threadId: v2ThreadId,
    ordinal,
    providerInstanceId: v2Projection.thread.providerInstanceId,
    modelSelection: v2Projection.thread.modelSelection,
    providerThreadId: null,
    userMessageId: MessageId.make(`message-${ordinal}`),
    rootNodeId: null,
    activeAttemptId: null,
    status,
    requestedAt: v2Now,
    startedAt: v2Now,
    completedAt: status === "completed" ? v2Now : null,
    checkpointId: CheckpointId.make(`checkpoint-${ordinal}`),
    contextHandoffId: null,
  };
}

function checkpoint(
  ordinal: number,
  status: OrchestrationV2Checkpoint["status"] = "ready",
): OrchestrationV2Checkpoint {
  return {
    id: CheckpointId.make(`checkpoint-${ordinal}`),
    threadId: v2ThreadId,
    scopeId: CheckpointScopeId.make("scope-1"),
    runId: RunId.make(`run-${ordinal}`),
    nodeId: NodeId.make(`node-${ordinal}`),
    parentCheckpointId: null,
    ordinalWithinScope: ordinal,
    appRunOrdinal: ordinal,
    ref: CheckpointRef.make(`refs/hal-c2/checkpoints/${ordinal}`),
    status,
    files: [],
    capturedAt: v2Now,
  };
}

describe("checkpoint turn counts", () => {
  it("numbers turns by standing completed runs, as the MC does", () => {
    // Runs 2 and 3 were rewound, run 5 was interrupted, and run 6 is the
    // new run after the rewind: the diff turns are 1 (run 1), 2 (run 4 is
    // still standing), and 3 (run 6).
    const projection: OrchestrationV2ThreadProjection = {
      ...v2Projection,
      runs: [
        run(1, "completed"),
        run(2, "rolled_back"),
        run(3, "rolled_back"),
        run(4, "completed"),
        run(5, "interrupted"),
        run(6, "completed"),
      ],
      checkpoints: [
        checkpoint(1),
        checkpoint(2, "stale"),
        checkpoint(3, "stale"),
        checkpoint(4),
        checkpoint(6),
      ],
    };

    expect(diffCheckpoints(projection).map((entry) => entry.appRunOrdinal)).toEqual([1, 4, 6]);
    expect(
      deriveThreadCheckpointSummaries(projection).map((summary) => [
        summary.runId,
        summary.checkpointTurnCount,
      ]),
    ).toEqual([
      ["run-1", 1],
      // Rewound checkpoints carry no turn count: their run ordinal could
      // equal a standing turn's position and be taken for it.
      ["run-2", 0],
      ["run-3", 0],
      ["run-4", 2],
      ["run-6", 3],
    ]);
  });
});
