import {
  halC2ResultFailed,
  halC2Tool,
  summarizeHalC2ToolCalls,
  type HalC2ToolCall,
  type HalC2ToolSummaryAction,
} from "./halC2Tools.ts";

// What a group of the agent's tool calls did, in one sentence, and whether one
// of them failed (port of packages/client-runtime/src/work-log/presentation.ts
// summarizeToolGroup; the desktop's is apps/desktop-qt/src/native/TimelineSummary.cpp).
// Calls are the MC's turn items as the client gets them.

export type TurnItemRecord = Readonly<Record<string, unknown>>;

type ToolGroupAction =
  | "read"
  | "edit"
  | "command"
  | "thread-create"
  | "search"
  | "code-search"
  | "other"
  | "update";

const text = (item: TurnItemRecord, key: string): string =>
  typeof item[key] === "string" ? (item[key] as string) : "";

/** The MC projects a read as a search for the one file it read (acp/thread_runtime.ex). */
export function isFileRead(item: TurnItemRecord): boolean {
  if (item.type !== "file_search") return false;
  const results = Array.isArray(item.results) ? item.results : [];
  const pattern = text(item, "pattern");
  return (
    results.length === 1 &&
    pattern !== "" &&
    (results[0] as { fileName?: unknown } | null)?.fileName === pattern
  );
}

/** The HAL-C2 tool a dynamic tool call is, if it is one of HAL-C2's. */
export function halC2ToolOf(item: TurnItemRecord) {
  return item.type === "dynamic_tool" ? halC2Tool(text(item, "toolName")) : null;
}

/**
 * Whether the call failed: the provider said so or the user declined it, a
 * command exited non-zero or its output says it failed, or HAL-C2's tool
 * answered with an error.
 */
export function callFailed(item: TurnItemRecord): boolean {
  if (item.status === "failed" || item.status === "declined") return true;
  if (item.type === "command_execution") {
    return (
      item.outputIndicatesFailure === true ||
      (typeof item.exitCode === "number" && item.exitCode !== 0)
    );
  }
  return halC2ToolOf(item) !== null && halC2ResultFailed(item.output);
}

function actionOf(item: TurnItemRecord): ToolGroupAction {
  switch (item.type) {
    case "thread_created":
      return "thread-create";
    case "approval_request":
      return item.requestKind === "file-read" ? "read" : "other";
    case "dynamic_tool": {
      const title = text(item, "title").trim() || text(item, "toolName").trim();
      return item.viewedImagePath !== undefined || /^read(?:\s+file)?$/i.test(title)
        ? "read"
        : "other";
    }
    case "file_search":
      return isFileRead(item) ? "read" : "code-search";
    case "file_change":
      return "edit";
    case "command_execution":
      return "command";
    case "web_search":
      return "search";
    // Notices and plan updates are news, not tools.
    case "system_notice":
    case "todo_list":
    case "run_interrupt_request":
    case "run_interrupt_result":
      return "update";
    default:
      return "other";
  }
}

const times = (count: number, noun: string, plural = `${noun}s`) =>
  `${count} ${count === 1 ? noun : plural}`;

function actionLabel(action: ToolGroupAction, count: number): string {
  switch (action) {
    case "read":
      return `Read ${times(count, "file")}`;
    case "edit":
      return `Changed ${times(count, "file")}`;
    case "command":
      return `Ran ${times(count, "command")}`;
    case "thread-create":
      return `Created ${times(count, "thread")}`;
    case "search":
      return `Searched the web ${times(count, "time")}`;
    case "code-search":
      return `Searched code ${times(count, "time")}`;
    case "other":
      return `Used ${times(count, "tool")}`;
    case "update":
      return `Received ${times(count, "update")}`;
  }
}

// What changed something is named before what only looked; tools and news last.
const CHANGES = new Set<ToolGroupAction | HalC2ToolSummaryAction>([
  "command",
  "edit",
  "delegate",
  "task-cancel",
  "thread-create",
  "thread-send",
  "thread-interrupt",
  "schedule-create",
  "schedule-update",
  "schedule-delete",
  "schedule-run",
  "thread-configure",
  "thread-fork",
  "thread-merge",
  "thread-organize",
  "thread-update",
  "queue-edit",
  "queue-cancel",
  "queue-reorder",
  "queue-steer",
  "question-respond",
  "worktree-handoff",
  "project-create",
  "project-update",
  "project-delete",
  "project-clone",
  "environment-update",
  "attachment-prepare",
  "attachment-discard",
  "attachment-send",
]);

function priority(action: ToolGroupAction | HalC2ToolSummaryAction): number {
  if (CHANGES.has(action)) return 0;
  return action === "other" || action === "update" ? 2 : 1;
}

function halC2Call(item: TurnItemRecord): HalC2ToolCall {
  return {
    input: item.input,
    output: item.output,
    outcome:
      item.status === "completed"
        ? "completed"
        : item.status === "failed" || item.status === "declined"
          ? "failed"
          : "unfinished",
  };
}

interface ToolSource {
  readonly key: string;
  readonly name: string;
  readonly kind: string;
}

function sourceOf(item: TurnItemRecord): ToolSource | null {
  const source = item.toolSource as Partial<ToolSource> | undefined;
  return source && typeof source.key === "string" && typeof source.name === "string"
    ? { key: source.key, name: source.name, kind: String(source.kind ?? "") }
    : null;
}

const sentence = (parts: ReadonlyArray<string>) =>
  parts.length < 3 ? parts.join(" and ") : `${parts.slice(0, -1).join(", ")}, and ${parts.at(-1)}`;

/**
 * A group of calls in one sentence: calls through a named integration first,
 * then at most two kinds of work, changes before looks, and the rest counted.
 * Reasoning is left out, and a group of only reasoning is a thought.
 */
export function summarizeToolCalls(all: ReadonlyArray<TurnItemRecord>): {
  readonly text: string;
  readonly failed: boolean;
} {
  const items = all.filter((item) => item.type !== "reasoning");
  if (items.length === 0) {
    return { text: all.length === 1 ? "Thought" : `Thought (×${all.length})`, failed: false };
  }
  const sources = new Map<string, ToolSource>();
  const groups = new Map<
    ToolGroupAction | HalC2ToolSummaryAction,
    { action: ToolGroupAction; halC2: HalC2ToolSummaryAction | null; items: TurnItemRecord[] }
  >();
  for (const item of items) {
    const halC2 = halC2ToolOf(item)?.summaryAction ?? null;
    const source = sourceOf(item);
    if (source && halC2 === null) {
      sources.set(source.key, source);
      continue;
    }
    const action = actionOf(item);
    const group = groups.get(halC2 ?? action);
    if (group) group.items.push(item);
    else groups.set(halC2 ?? action, { action, halC2, items: [item] });
  }
  const named = [...groups].map(([key, group], index) => {
    if (group.halC2) {
      const { label, failedCount } = summarizeHalC2ToolCalls(
        group.halC2,
        group.items.map(halC2Call),
      );
      return {
        index,
        count: group.items.length,
        priority: priority(key),
        label,
        failed: failedCount > 0,
      };
    }
    // Edits count the files they touched.
    const files = new Set(group.items.map((item) => text(item, "fileName")).filter(Boolean));
    const count =
      group.action === "edit"
        ? files.size + group.items.filter((item) => text(item, "fileName") === "").length
        : group.items.length;
    return {
      index,
      count: group.items.length,
      priority: priority(key),
      label: actionLabel(group.action, count),
      failed: group.items.some(callFailed),
    };
  });
  const selected = [...named]
    .sort((a, b) => a.priority - b.priority || a.index - b.index)
    .slice(0, 2)
    .sort((a, b) => a.index - b.index);
  const labels = selected.map((group) => group.label);
  if (sources.size > 0) {
    const values = [...sources.values()];
    const integrations = values.every((source) => source.kind === "integration")
      ? ` ${values.length === 1 ? "integration" : "integrations"}`
      : "";
    labels.unshift(`Used ${sentence(values.map((source) => source.name))}${integrations}`);
  }
  const sourced = items.filter((item) => sourceOf(item) && !halC2ToolOf(item)).length;
  const remaining = items.length - sourced - selected.reduce((sum, group) => sum + group.count, 0);
  if (remaining > 0) labels.push(`Performed ${times(remaining, "other action")}`);
  return {
    text: sentence(
      labels.map((label, index) =>
        index === 0 ? label : label[0]!.toLowerCase() + label.slice(1),
      ),
    ),
    failed: named.some((group) => group.failed),
  };
}

/** A command as the user wrote it: a `sh -c` wrapper left out, its first line only. */
export function commandDisplayText(command: string): string {
  const trimmed = command.trim();
  const wrapper =
    /^(?:\S*\/)?(?:ba|z|da|k)?sh(?:\.exe)?(?:\s+-[A-Za-z]+)*?\s+-[A-Za-z]*c\s+(?:'((?:[^']|'\\'')*)'|"((?:[^"\\]|\\.)*)"|([^\s'"]+))$/s.exec(
      trimmed,
    );
  const script = !wrapper
    ? trimmed
    : wrapper[1] !== undefined
      ? wrapper[1].replaceAll("'\\''", "'")
      : wrapper[2] !== undefined
        ? wrapper[2].replace(/\\(.)/gs, "$1")
        : wrapper[3]!;
  const shown = script.trim() || trimmed;
  return shown.split("\n")[0]!.replace(/\s+/g, " ").trim();
}

/** A path inside the workspace, relative to its root; any other path as it is. */
export function workspaceRelative(path: string, root: string | null | undefined): string {
  if (!root) return path;
  const base = root.endsWith("/") ? root : `${root}/`;
  return path.startsWith(base) ? path.slice(base.length) : path;
}
