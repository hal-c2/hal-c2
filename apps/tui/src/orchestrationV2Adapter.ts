import {
  type OrchestrationShellSnapshot,
  type OrchestrationThread,
  type OrchestrationThreadActivity,
  type OrchestrationThreadShell,
  type OrchestrationV2Run,
  type OrchestrationV2ShellSnapshot,
  type OrchestrationV2ThreadProjection,
  type OrchestrationV2ThreadShell,
  type OrchestrationV2TurnItem,
} from "@hal-c2/contracts";
import { deriveThreadCheckpointSummaries } from "@hal-c2/client-runtime/state/thread-checkpoints";
import {
  deriveLatestThreadRun,
  deriveThreadRuntime,
} from "@hal-c2/client-runtime/state/thread-execution";
import * as DateTime from "effect/DateTime";

// The TUI still uses its compact legacy-shaped presentation model. Keep that
// compatibility at the connection boundary while the server and shared client
// runtime expose only native orchestration-v2 projections.

const iso = (value: DateTime.Utc): string => DateTime.formatIso(value);
const nullableIso = (value: DateTime.Utc | null): string | null =>
  value === null ? null : iso(value);

export type TuiThreadShell = Omit<OrchestrationThreadShell, "snoozedUntil" | "snoozedAt"> &
  Pick<OrchestrationV2ThreadShell, "lineage"> & {
    // Always present (null when unset) so client-runtime's snooze helpers accept it.
    readonly snoozedUntil: string | null;
    readonly snoozedAt: string | null;
  };
export type TuiShellSnapshot = Omit<OrchestrationShellSnapshot, "threads"> & {
  readonly threads: ReadonlyArray<TuiThreadShell>;
};

function legacyRunState(
  status: OrchestrationV2Run["status"],
): NonNullable<OrchestrationThread["latestTurn"]>["state"] {
  switch (status) {
    case "completed":
      return "completed";
    case "failed":
      return "error";
    case "interrupted":
    case "cancelled":
    case "rolled_back":
      return "interrupted";
    case "preparing":
    case "queued":
    case "starting":
    case "running":
    case "waiting":
      return "running";
  }
}

function legacySessionStatus(
  status: NonNullable<ReturnType<typeof deriveThreadRuntime>>["status"],
): NonNullable<OrchestrationThread["session"]>["status"] {
  switch (status) {
    case "preparing":
    case "queued":
    case "starting":
      return "starting";
    case "running":
    case "waiting":
      return "running";
    case "completed":
      return "ready";
    case "failed":
      return "error";
    case "interrupted":
    case "cancelled":
    case "rolled_back":
      return "interrupted";
    case "idle":
      return "idle";
  }
}

function shellLatestTurn(
  thread: OrchestrationV2ThreadShell,
): OrchestrationThreadShell["latestTurn"] {
  if (thread.latestRunId === null) return null;
  const status = thread.status === "idle" ? "completed" : thread.status;
  return {
    turnId: thread.latestRunId as unknown as NonNullable<
      OrchestrationThreadShell["latestTurn"]
    >["turnId"],
    state: legacyRunState(status),
    requestedAt: nullableIso(thread.latestRunRequestedAt ?? null) ?? iso(thread.createdAt),
    startedAt: nullableIso(thread.latestRunStartedAt ?? null),
    completedAt: nullableIso(thread.latestRunCompletedAt ?? null),
    assistantMessageId: null,
  };
}

function shellSession(thread: OrchestrationV2ThreadShell): OrchestrationThreadShell["session"] {
  if (thread.latestRunId === null && thread.activeProviderThreadId === null) return null;
  const status = thread.activityRunStatus ?? thread.status;
  return {
    threadId: thread.id,
    status: legacySessionStatus(status),
    providerName: null,
    providerInstanceId: thread.providerInstanceId,
    runtimeMode: thread.runtimeMode,
    activeTurnId:
      thread.activeRunId === null
        ? null
        : (thread.activeRunId as unknown as NonNullable<
            OrchestrationThreadShell["session"]
          >["activeTurnId"]),
    lastError: (thread.lastError ?? null) as NonNullable<
      OrchestrationThreadShell["session"]
    >["lastError"],
    updatedAt: iso(thread.updatedAt),
  };
}

export function presentTuiThreadShell(thread: OrchestrationV2ThreadShell): TuiThreadShell {
  return {
    id: thread.id,
    projectId: thread.projectId,
    title: thread.title,
    lineage: thread.lineage,
    modelSelection: thread.modelSelection,
    runtimeMode: thread.runtimeMode,
    interactionMode: thread.interactionMode,
    branch: thread.branch,
    worktreePath: thread.worktreePath,
    pullRequests: thread.pullRequests ?? [],
    latestTurn: shellLatestTurn(thread),
    createdAt: iso(thread.createdAt),
    updatedAt: iso(thread.updatedAt),
    archivedAt: nullableIso(thread.archivedAt),
    settledOverride: thread.settledOverride,
    settledAt: nullableIso(thread.settledAt),
    snoozedUntil: nullableIso(thread.snoozedUntil ?? null),
    snoozedAt: nullableIso(thread.snoozedAt ?? null),
    pinnedAt: nullableIso(thread.pinnedAt ?? null),
    pinOrderKey: thread.pinOrderKey ?? null,
    titleRegeneration:
      thread.titleRegeneration == null
        ? null
        : {
            requestId: thread.titleRegeneration.requestId,
            startedAt: iso(thread.titleRegeneration.startedAt),
          },
    session: shellSession(thread),
    latestUserMessageAt: nullableIso(thread.latestUserMessageAt),
    hasPendingApprovals:
      thread.pendingRuntimeRequest !== null &&
      thread.pendingRuntimeRequest.kind !== "user_input" &&
      thread.pendingRuntimeRequest.kind !== "auth_refresh",
    hasPendingUserInput: thread.pendingRuntimeRequest?.kind === "user_input",
    hasActionableProposedPlan: thread.hasActionableProposedPlan,
    backgroundLiveness: (thread.pendingBackgroundTasks?.length ?? 0) > 0 ? "working" : null,
  };
}

export function presentTuiShell(snapshot: OrchestrationV2ShellSnapshot): TuiShellSnapshot {
  const sourceThreads = [...snapshot.threads, ...snapshot.archivedThreads];
  const updatedAt = sourceThreads.reduce(
    (latest, thread) => {
      const candidate = iso(thread.updatedAt);
      return candidate > latest ? candidate : latest;
    },
    snapshot.projects.reduce(
      (latest, project) => (project.updatedAt > latest ? project.updatedAt : latest),
      "1970-01-01T00:00:00.000Z",
    ),
  );
  return {
    snapshotSequence: snapshot.snapshotSequence,
    projects: snapshot.projects,
    threads: sourceThreads.map(presentTuiThreadShell),
    updatedAt,
  };
}

function itemStatus(item: OrchestrationV2TurnItem): string {
  switch (item.status) {
    case "idle":
    case "pending":
    case "running":
    case "waiting":
      return "inProgress";
    case "completed":
      return "completed";
    case "failed":
      return "failed";
    case "cancelled":
    case "interrupted":
      return "stopped";
  }
}

/** The MC projects a read as a search for the one file it read (acp/thread_runtime.ex). */
function isFileRead(item: Extract<OrchestrationV2TurnItem, { type: "file_search" }>): boolean {
  return item.results?.length === 1 && item.results[0]?.fileName === item.pattern;
}

/** How a subagent stands, as the web's lifecycle row words it (V2LifecycleRow STATUS_VISUALS). */
function subagentStatusLabel(status: OrchestrationV2TurnItem["status"]): string {
  switch (status) {
    case "idle":
      return "Idle · resumable";
    case "completed":
      return "Completed";
    case "failed":
      return "Failed";
    case "cancelled":
    case "interrupted":
      return "Stopped";
    default:
      return "Working";
  }
}

/** Reasoning reads "Thinking" while it is written and "Thought" once it is done. */
function reasoningLabel(item: Extract<OrchestrationV2TurnItem, { type: "reasoning" }>): string {
  return item.streaming || item.status === "running" ? "Thinking" : "Thought";
}

/** How an answered approval ended, as its row's status (a pending one carries none). */
function approvalOutcome(
  request: OrchestrationV2ThreadProjection["runtimeRequests"][number] | undefined,
): { status?: string } {
  if (!request || request.status === "pending") return {};
  if (request.decision === "decline") return { status: "declined" };
  if (request.decision === "cancel" || request.status !== "resolved") return { status: "stopped" };
  return { status: "completed" };
}

function itemSummary(item: OrchestrationV2TurnItem): string {
  if (item.type === "reasoning") return reasoningLabel(item);
  if (item.title?.trim()) return item.title.trim();
  switch (item.type) {
    case "command_execution":
      return "Ran command";
    case "file_change":
      return `Changed ${item.fileName}`;
    case "file_search":
      return isFileRead(item) ? "Read file" : "Searched files";
    case "web_search":
      return "Searched the web";
    case "approval_request":
      return "Approval requested";
    case "user_input_request":
      return "Input requested";
    case "error":
      return item.failure.message;
    case "system_notice":
      return item.message;
    case "notification":
      return item.summary;
    case "subagent":
      return "Subagent";
    case "dynamic_tool":
      return item.toolName ?? "Used tool";
    case "compaction":
      return "Context compacted";
    case "handoff":
      return "Context handoff";
    case "fork":
      return "Conversation fork";
    case "thread_created":
      return "Created thread";
    case "run_interrupt_request":
    case "run_interrupt_result":
      return item.message;
    case "checkpoint":
      return "Checkpoint captured";
    case "proposed_plan":
      return "Proposed plan";
    case "todo_list":
      return "Updated plan";
    case "user_message":
    case "assistant_message":
      return "Message";
  }
}

function itemPayload(
  item: OrchestrationV2TurnItem,
  projection: OrchestrationV2ThreadProjection,
): Record<string, unknown> {
  const status = itemStatus(item);
  switch (item.type) {
    case "reasoning":
      return { title: reasoningLabel(item), detail: item.text, status };
    case "command_execution":
      return {
        title: itemSummary(item),
        detail: item.output,
        itemType: item.type,
        status,
        data: { item: { command: item.input, result: { output: item.output } } },
      };
    case "file_change":
      return {
        title: itemSummary(item),
        detail: item.diffStr,
        itemType: item.type,
        status,
        data: { item: { path: item.fileName } },
      };
    case "file_search":
      return {
        title: itemSummary(item),
        detail: item.pattern,
        icon: isFileRead(item) ? "fileRead" : "fileSearch",
        status,
      };
    case "web_search":
      return {
        title: itemSummary(item),
        itemType: item.type,
        detail: item.patterns?.join(", "),
        status,
      };
    case "dynamic_tool":
      return {
        title: item.toolName ?? "Used tool",
        itemType: "dynamic_tool_call",
        // The web's work entries show a tool the provider did not classify as a wrench.
        icon: "mcp",
        status,
        data: { item: { input: item.input, result: item.output } },
      };
    case "subagent": {
      // The model is the subagent's own, never the parent thread's.
      const model = projection.subagents.find((entry) => entry.id === item.subagentId)?.model;
      const detail = [model, item.progress ?? item.result ?? item.prompt]
        .filter((part): part is string => typeof part === "string" && part.trim().length > 0)
        .join(" · ");
      return {
        title: itemSummary(item),
        detail,
        icon: "subagent",
        // An idle subagent waits to be resumed: nothing is running.
        status: item.status === "idle" ? "stopped" : status,
        statusLabel: subagentStatusLabel(item.status),
        childThreadId: item.childThreadId,
        ...(model ? { model } : {}),
      };
    }
    case "approval_request": {
      const request = projection.runtimeRequests.find(
        (candidate) => candidate.id === item.requestId,
      );
      return {
        requestId: item.requestId,
        requestKind: item.requestKind,
        detail: item.prompt,
        ...approvalOutcome(request),
        ...(item.options ? { options: item.options } : {}),
        ...(item.appName ? { appName: item.appName } : {}),
        // The provider process that asked is gone: nothing can take the answer.
        ...(request?.responseCapability.type === "not_resumable" ? { notResumable: true } : {}),
      };
    }
    case "user_input_request":
      return {
        requestId: item.requestId,
        questions: item.questions.map((question) => ({
          ...question,
          multiSelect: question.multiSelect === true,
        })),
      };
    case "error":
      return { title: "Error", detail: item.failure.message, status: "failed", data: item };
    default:
      return { title: itemSummary(item), status, data: item };
  }
}

function itemActivityKind(
  item: OrchestrationV2TurnItem,
  projection: OrchestrationV2ThreadProjection,
): string | null {
  if (item.type === "user_message" || item.type === "assistant_message") return null;
  if (item.type === "checkpoint" || item.type === "proposed_plan" || item.type === "todo_list") {
    return null;
  }
  if (item.type === "reasoning") {
    return item.status === "running" ? "task.progress" : "task.completed";
  }
  if (item.type === "approval_request" || item.type === "user_input_request") {
    const request = projection.runtimeRequests.find((candidate) => candidate.id === item.requestId);
    const pending = request?.status === "pending";
    return item.type === "approval_request"
      ? pending
        ? "approval.requested"
        : "approval.resolved"
      : pending
        ? "user-input.requested"
        : "user-input.resolved";
  }
  return item.status === "running" || item.status === "waiting" ? "tool.updated" : "tool.completed";
}

function presentActivity(
  projected: OrchestrationV2ThreadProjection["visibleTurnItems"][number],
  projection: OrchestrationV2ThreadProjection,
): OrchestrationThreadActivity | null {
  const item = projected.item;
  const kind = itemActivityKind(item, projection);
  if (kind === null) return null;
  const createdAt =
    nullableIso(item.startedAt) ?? nullableIso(item.completedAt) ?? iso(item.updatedAt);
  return {
    id: item.id as unknown as OrchestrationThreadActivity["id"],
    tone:
      item.type === "error"
        ? "error"
        : item.type === "approval_request" || item.type === "user_input_request"
          ? "approval"
          : item.type === "reasoning"
            ? "info"
            : "tool",
    kind: kind as OrchestrationThreadActivity["kind"],
    summary: itemSummary(item) as OrchestrationThreadActivity["summary"],
    payload: itemPayload(item, projection),
    turnId: item.runId as unknown as OrchestrationThreadActivity["turnId"],
    sequence: projected.position,
    createdAt,
  };
}

export function presentTuiThread(projection: OrchestrationV2ThreadProjection): OrchestrationThread {
  const thread = projection.thread;
  const latestRun = deriveLatestThreadRun(projection);
  const runtime = deriveThreadRuntime(projection);
  const proposedPlans = projection.plans.flatMap((plan) => {
    if (plan.kind !== "proposed_plan") return [];
    const item = projection.turnItems.findLast(
      (candidate) => candidate.type === "proposed_plan" && candidate.planId === plan.id,
    );
    const updatedAt = item ? iso(item.updatedAt) : iso(projection.updatedAt);
    return [
      {
        id: plan.id as unknown as OrchestrationThread["proposedPlans"][number]["id"],
        turnId: plan.runId as unknown as OrchestrationThread["proposedPlans"][number]["turnId"],
        planMarkdown: plan.markdown as OrchestrationThread["proposedPlans"][number]["planMarkdown"],
        implementedAt:
          plan.status === "completed" || plan.status === "superseded" ? updatedAt : null,
        implementationThreadId: null,
        createdAt: item ? (nullableIso(item.startedAt) ?? updatedAt) : updatedAt,
        updatedAt,
      },
    ];
  });
  const session: OrchestrationThread["session"] =
    runtime === null
      ? null
      : {
          threadId: thread.id,
          status: legacySessionStatus(runtime.status),
          providerName: runtime.providerName as NonNullable<
            OrchestrationThread["session"]
          >["providerName"],
          providerInstanceId: runtime.providerInstanceId,
          runtimeMode: thread.runtimeMode,
          activeTurnId: runtime.activeRunId as unknown as NonNullable<
            OrchestrationThread["session"]
          >["activeTurnId"],
          lastError: runtime.lastError as NonNullable<OrchestrationThread["session"]>["lastError"],
          updatedAt: runtime.updatedAt,
        };
  return {
    id: thread.id,
    projectId: thread.projectId,
    title: thread.title,
    modelSelection: thread.modelSelection,
    runtimeMode: thread.runtimeMode,
    interactionMode: thread.interactionMode,
    branch: thread.branch,
    worktreePath: thread.worktreePath,
    pullRequests: thread.pullRequests ?? [],
    latestTurn:
      latestRun === null
        ? null
        : {
            turnId: latestRun.runId as unknown as NonNullable<
              OrchestrationThread["latestTurn"]
            >["turnId"],
            state: legacyRunState(latestRun.status),
            requestedAt: latestRun.requestedAt ?? iso(thread.createdAt),
            startedAt: latestRun.startedAt,
            completedAt: latestRun.completedAt,
            assistantMessageId: latestRun.assistantMessageId,
            ...(latestRun.sourcePlanRef === undefined
              ? {}
              : {
                  sourceProposedPlan: {
                    threadId: latestRun.sourcePlanRef.threadId,
                    planId: latestRun.sourcePlanRef.planId as unknown as NonNullable<
                      NonNullable<OrchestrationThread["latestTurn"]>["sourceProposedPlan"]
                    >["planId"],
                  },
                }),
          },
    createdAt: iso(thread.createdAt),
    updatedAt: iso(thread.updatedAt),
    archivedAt: nullableIso(thread.archivedAt),
    settledOverride: thread.settledOverride,
    settledAt: nullableIso(thread.settledAt),
    snoozedUntil: nullableIso(thread.snoozedUntil ?? null),
    snoozedAt: nullableIso(thread.snoozedAt ?? null),
    pinnedAt: nullableIso(thread.pinnedAt ?? null),
    pinOrderKey: thread.pinOrderKey ?? null,
    titleRegeneration:
      thread.titleRegeneration == null
        ? null
        : {
            requestId: thread.titleRegeneration.requestId,
            startedAt: iso(thread.titleRegeneration.startedAt),
          },
    deletedAt: nullableIso(thread.deletedAt),
    messages: projection.messages.map((message) => ({
      id: message.id,
      role: message.role,
      text: message.text,
      attachments: message.attachments,
      turnId: message.runId as unknown as OrchestrationThread["messages"][number]["turnId"],
      streaming: message.streaming,
      createdAt: iso(message.createdAt),
      updatedAt: iso(message.updatedAt),
    })),
    proposedPlans,
    activities: projection.visibleTurnItems.flatMap((item) => {
      const activity = presentActivity(item, projection);
      return activity === null ? [] : [activity];
    }),
    checkpoints: deriveThreadCheckpointSummaries(projection).flatMap((checkpoint) =>
      checkpoint.status === "stale"
        ? []
        : [
            {
              turnId:
                checkpoint.runId as unknown as OrchestrationThread["checkpoints"][number]["turnId"],
              checkpointTurnCount: checkpoint.checkpointTurnCount,
              checkpointRef: checkpoint.checkpointRef,
              status: checkpoint.status,
              files: checkpoint.files,
              assistantMessageId: checkpoint.assistantMessageId,
              completedAt: checkpoint.completedAt,
            },
          ],
    ),
    session,
  };
}
