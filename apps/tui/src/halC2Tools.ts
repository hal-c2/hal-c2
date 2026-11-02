// HAL-C2's own tools, as a call to one reads in the timeline: the name it is
// shown by, the kind of work a summary counts it as, and what a group of such
// calls did (port of packages/shared/src/halC2McpToolPresentation.ts and
// packages/client-runtime/src/halC2ToolSummary.ts).

export type HalC2ToolSummaryAction =
  | "capabilities"
  | "delegate"
  | "task-status"
  | "task-cancel"
  | "schedule-run"
  | "schedule-create"
  | "schedule-list"
  | "schedule-update"
  | "schedule-delete"
  | "thread-create"
  | "thread-list"
  | "thread-read"
  | "thread-send"
  | "thread-wait"
  | "thread-interrupt"
  | "thread-configuration"
  | "thread-configure"
  | "thread-fork"
  | "thread-merge"
  | "thread-search"
  | "thread-transfers"
  | "thread-organize"
  | "thread-update"
  | "queue-list"
  | "queue-read"
  | "queue-edit"
  | "queue-cancel"
  | "queue-reorder"
  | "queue-steer"
  | "question-list"
  | "question-read"
  | "question-respond"
  | "worktree-handoff"
  | "worktree-list"
  | "worktree-status"
  | "project-list"
  | "project-read"
  | "project-create"
  | "project-update"
  | "project-delete"
  | "project-clone"
  | "environment-read"
  | "environment-update"
  | "attachment-prepare"
  | "attachment-discard"
  | "attachment-send"
  | "link-pr"
  | "unlink-pr"
  | "list-prs"
  | "browser"
  | "device";

export interface HalC2ToolDefinition {
  readonly displayName: string;
  readonly labels: readonly [action: string, running: string, completed: string, detail: string];
  readonly icon: "hal-c2" | "browser" | "device" | "pull-request";
  readonly summaryAction: HalC2ToolSummaryAction;
}

function tool(
  labels: HalC2ToolDefinition["labels"],
  summaryAction: HalC2ToolSummaryAction,
  icon: HalC2ToolDefinition["icon"] = "hal-c2",
  displayName = `${labels[0]} ${labels[3]}`,
): HalC2ToolDefinition {
  return { displayName, labels, icon, summaryAction };
}

const HAL_C2_SERVER_ALIASES = new Set(["hal-c2", "hal_c2", "halc2"]);

// Every HAL-C2 tool a call can name; a name not in it stays an ordinary tool call.
const HAL_C2_TOOLS: Readonly<Record<string, HalC2ToolDefinition>> = {
  link_pull_request: tool(
    ["Link", "Linking", "Linked", "a pull request"],
    "link-pr",
    "pull-request",
  ),
  unlink_pull_request: tool(
    ["Unlink", "Unlinking", "Unlinked", "a pull request"],
    "unlink-pr",
    "pull-request",
  ),
  list_thread_pull_requests: tool(
    ["Check", "Checking", "Checked", "linked pull requests"],
    "list-prs",
    "pull-request",
  ),
  orchestrator_capabilities: tool(
    ["Get", "Getting", "Got", "orchestration capabilities"],
    "capabilities",
  ),
  delegate_task: tool(["Delegate", "Delegating", "Delegated", "a child task"], "delegate"),
  task_status: tool(["Get", "Getting", "Got", "delegated task status"], "task-status"),
  task_cancel: tool(
    ["Cancel", "Canceling", "Requested cancellation of", "delegated task"],
    "task-cancel",
  ),
  schedule_task: tool(
    ["Schedule", "Scheduling", "Scheduled", "a recurring task"],
    "schedule-create",
  ),
  list_scheduled_tasks: tool(["List", "Listing", "Listed", "scheduled tasks"], "schedule-list"),
  update_scheduled_task: tool(
    ["Update", "Updating", "Updated", "a scheduled task"],
    "schedule-update",
  ),
  delete_scheduled_task: tool(
    ["Delete", "Deleting", "Requested deletion of", "a scheduled task"],
    "schedule-delete",
  ),
  create_threads: tool(["Create", "Creating", "Created", "HAL-C2 threads"], "thread-create"),
  hal_c2_thread_start: tool(["Start", "Starting", "Started", "a HAL-C2 thread"], "thread-create"),
  hal_c2_thread_list: tool(["List", "Listing", "Listed", "HAL-C2 threads"], "thread-list"),
  hal_c2_thread_read: tool(["Read", "Reading", "Read", "a HAL-C2 thread"], "thread-read"),
  hal_c2_thread_send: tool(["Send", "Sending", "Sent", "to a HAL-C2 thread"], "thread-send"),
  hal_c2_thread_wait: tool(["Wait", "Waiting", "Waited", "for a HAL-C2 thread"], "thread-wait"),
  hal_c2_thread_interrupt: tool(
    ["Interrupt", "Interrupting", "Requested an interrupt of", "a HAL-C2 thread"],
    "thread-interrupt",
  ),
  hal_c2_worktree_handoff: tool(
    ["Hand off", "Handing off", "Handed off", "thread to a git worktree"],
    "worktree-handoff",
  ),
  hal_c2_worktree_status: tool(
    ["Get", "Getting", "Got", "thread worktree status"],
    "worktree-status",
  ),
  preview_status: tool(["Get", "Getting", "Got", "preview browser status"], "browser", "browser"),
  preview_open: tool(
    ["Open", "Opening", "Opened", "a page in the preview browser"],
    "browser",
    "browser",
  ),
  preview_navigate: tool(
    ["Navigate", "Navigating", "Navigated", "the preview browser"],
    "browser",
    "browser",
  ),
  preview_snapshot: tool(
    ["Take a snapshot of", "Taking a snapshot of", "Took a snapshot of", "the preview page"],
    "browser",
    "browser",
    "Snapshot the preview page",
  ),
  preview_click: tool(
    ["Click", "Clicking", "Clicked", "in the preview browser"],
    "browser",
    "browser",
  ),
  preview_press: tool(
    ["Press", "Pressing", "Pressed", "a key in the preview browser"],
    "browser",
    "browser",
  ),
  preview_type: tool(["Type", "Typing", "Typed", "in the preview browser"], "browser", "browser"),
  preview_scroll: tool(
    ["Scroll", "Scrolling", "Scrolled", "the preview browser"],
    "browser",
    "browser",
  ),
  preview_resize: tool(
    ["Resize", "Resizing", "Resized", "the preview browser"],
    "browser",
    "browser",
  ),
  preview_evaluate: tool(
    ["Evaluate", "Evaluating", "Evaluated", "script in the preview browser"],
    "browser",
    "browser",
  ),
  preview_wait_for: tool(
    ["Wait", "Waiting", "Waited", "for the preview page"],
    "browser",
    "browser",
  ),
  preview_set_appearance: tool(
    ["Set", "Setting", "Set", "preview browser appearance"],
    "browser",
    "browser",
  ),
  preview_recording_start: tool(
    ["Start", "Starting", "Started", "recording the preview browser"],
    "browser",
    "browser",
  ),
  preview_recording_stop: tool(
    ["Stop", "Stopping", "Stopped", "recording the preview browser"],
    "browser",
    "browser",
  ),
  device_list: tool(["List", "Listing", "Listed", "simulators and emulators"], "device", "device"),
  device_open: tool(
    ["Open", "Opening", "Opened", "a device in the Device panel"],
    "device",
    "device",
  ),
  device_screenshot: tool(
    ["Take a screenshot of", "Taking a screenshot of", "Took a screenshot of", "the device"],
    "device",
    "device",
  ),
  device_close: tool(["Close", "Closing", "Closed", "a device"], "device", "device"),
  run_scheduled_task_now: tool(
    ["Run", "Running", "Requested a run of", "a scheduled task"],
    "schedule-run",
  ),
  hal_c2_queue_list: tool(["List", "Listing", "Listed", "queued messages"], "queue-list"),
  hal_c2_queue_read: tool(["Read", "Reading", "Read", "a queued message"], "queue-read"),
  hal_c2_queue_edit: tool(["Edit", "Editing", "Edited", "a queued message"], "queue-edit"),
  hal_c2_queue_cancel: tool(
    ["Cancel", "Canceling", "Requested cancellation of", "a queued run"],
    "queue-cancel",
  ),
  hal_c2_queue_reorder: tool(
    ["Reorder", "Reordering", "Reordered", "a queued run"],
    "queue-reorder",
  ),
  hal_c2_queue_promote_to_steer: tool(
    ["Steer with", "Steering with", "Requested steering with", "a queued message"],
    "queue-steer",
  ),
  hal_c2_pending_request_list: tool(
    ["List", "Listing", "Listed", "pending questions"],
    "question-list",
  ),
  hal_c2_pending_request_read: tool(
    ["Read", "Reading", "Read", "pending questions"],
    "question-read",
  ),
  hal_c2_pending_request_respond: tool(
    ["Answer", "Answering", "Answered", "pending questions"],
    "question-respond",
  ),
  hal_c2_thread_configuration: tool(
    ["Read", "Reading", "Read", "thread configuration"],
    "thread-configuration",
  ),
  hal_c2_thread_configure: tool(["Set", "Setting", "Set", "thread model"], "thread-configure"),
  hal_c2_thread_fork: tool(
    ["Fork", "Forking", "Requested a fork of", "this thread"],
    "thread-fork",
  ),
  hal_c2_thread_merge_back: tool(
    ["Merge", "Merging", "Requested a merge of", "thread context"],
    "thread-merge",
  ),
  hal_c2_thread_search: tool(
    ["Search", "Searching", "Searched", "thread content"],
    "thread-search",
  ),
  hal_c2_thread_transfers: tool(
    ["Read", "Reading", "Read", "thread transfers"],
    "thread-transfers",
  ),
  hal_c2_thread_organize: tool(
    ["Organize", "Organizing", "Organized", "a thread"],
    "thread-organize",
  ),
  hal_c2_thread_update: tool(
    ["Update", "Updating", "Updated", "HAL-C2 thread metadata"],
    "thread-update",
  ),
  hal_c2_worktree_list: tool(["List", "Listing", "Listed", "workspace branches"], "worktree-list"),
  hal_c2_preview_list: tool(["List", "Listing", "Listed", "preview tabs"], "browser", "browser"),
  hal_c2_preview_close: tool(["Close", "Closing", "Closed", "a preview tab"], "browser", "browser"),
  hal_c2_environment_read: tool(
    ["Read", "Reading", "Read", "environment preferences"],
    "environment-read",
  ),
  hal_c2_environment_preferences_update: tool(
    ["Update", "Updating", "Updated", "environment preferences"],
    "environment-update",
  ),
  hal_c2_thread_launch: tool(
    ["Launch", "Launching", "Launched", "a project thread"],
    "thread-create",
  ),
  hal_c2_project_list: tool(["List", "Listing", "Listed", "projects"], "project-list"),
  hal_c2_project_read: tool(["Read", "Reading", "Read", "a project"], "project-read"),
  hal_c2_project_create: tool(
    ["Register", "Registering", "Registered", "a project"],
    "project-create",
  ),
  hal_c2_project_update: tool(["Update", "Updating", "Updated", "a project"], "project-update"),
  hal_c2_project_delete: tool(["Delete", "Deleting", "Deleted", "a project"], "project-delete"),
  hal_c2_project_clone: tool(["Clone", "Cloning", "Cloned", "a repository"], "project-clone"),
  hal_c2_attachment_prepare_upload: tool(
    ["Prepare", "Preparing", "Prepared", "an attachment upload"],
    "attachment-prepare",
  ),
  hal_c2_attachment_discard: tool(
    ["Discard", "Discarding", "Discarded", "a pending attachment"],
    "attachment-discard",
  ),
  hal_c2_thread_send_attachments: tool(
    ["Send", "Sending", "Sent", "attachments"],
    "attachment-send",
  ),
};

/**
 * The inventory name of a HAL-C2 tool, however the provider wrote it:
 * `mcp__hal-c2__x` (Claude, Cursor), `hal-c2.x` (Codex), other separators
 * registry agents use, a bare `x`, and a trailing " completed". Another
 * server's tool of the same name is not HAL-C2's.
 */
function resolveHalC2ToolName(value: string): string | null {
  const label = value.replace(/\s+(?:complete|completed)\s*$/i, "").trim();
  const mcp = /^mcp__(?<server>.+?)__(?<tool>.+)$/i.exec(label);
  if (mcp?.groups) {
    return HAL_C2_SERVER_ALIASES.has(mcp.groups.server!.toLowerCase()) ? mcp.groups.tool! : null;
  }
  const scoped = /^(?<server>hal[-_]?c2)(?:[.:/]|\s*·\s*)(?<tool>.+)$/i.exec(label);
  if (scoped?.groups) return scoped.groups.tool!;
  // Bare names start with `hal_c2_` themselves, so an exact match wins over the prefix strip.
  if (Object.hasOwn(HAL_C2_TOOLS, label)) return label;
  const tool = /^(?:mcp[-_]{1,2})?hal[-_ ]?c2(?:__|[-_.:/ ])(?<tool>.+)$/i.exec(label)?.groups
    ?.tool;
  return tool !== undefined && Object.hasOwn(HAL_C2_TOOLS, tool) ? tool : null;
}

export function halC2Tool(toolName: string | null | undefined): HalC2ToolDefinition | null {
  const name = toolName == null ? null : resolveHalC2ToolName(toolName);
  return name !== null && Object.hasOwn(HAL_C2_TOOLS, name) ? HAL_C2_TOOLS[name]! : null;
}

// --- what a group of calls did ------------------------------------------------------------

export interface HalC2ToolCall {
  readonly input: unknown;
  readonly output: unknown;
  readonly outcome: "completed" | "failed" | "unfinished";
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function id(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() !== "" ? value : undefined;
}

interface ToolResult {
  readonly data?: Record<string, unknown>;
  readonly failed: boolean;
}

/** An MCP result as the provider adapters keep it: JSON text, content blocks or structured content. */
function readResult(value: unknown, depth = 0): ToolResult {
  if (depth > 4) return { failed: false };
  if (typeof value === "string") {
    try {
      return readResult(JSON.parse(value), depth + 1);
    } catch {
      return { failed: false };
    }
  }
  if (Array.isArray(value)) {
    let data: ToolResult["data"];
    let failed = false;
    for (const block of value) {
      const record = asRecord(block);
      const text = record?.text ?? asRecord(record?.content)?.text;
      const result = readResult(asRecord(text)?.text ?? text, depth + 1);
      data ??= result.data;
      failed ||= result.failed;
    }
    return { ...(data ? { data } : {}), failed };
  }
  const record = asRecord(value);
  if (!record) return { failed: false };
  const failed =
    record.isError === true ||
    record.is_error === true ||
    (typeof record._tag === "string" && /(?:Error|Failure)$/.test(record._tag)) ||
    record.error != null;
  const content = record.structuredContent ?? record.content;
  if (content !== undefined) {
    const result = readResult(content, depth + 1);
    return { ...(result.data ? { data: result.data } : {}), failed: failed || result.failed };
  }
  return { data: record, failed };
}

function readInput(value: unknown): Record<string, unknown> | undefined {
  const input = readResult(value).data;
  // Cursor keeps its MCP args envelope; the other adapters keep the arguments.
  return input && typeof input.toolName === "string" ? asRecord(input.args) : input;
}

/** An MCP error comes back as the call's answer even when the provider finished the call. */
export function halC2ResultFailed(output: unknown): boolean {
  return readResult(output).failed;
}

function countEntities(ids: ReadonlyArray<string | undefined>): number {
  return (
    new Set(ids.filter((value) => value !== undefined)).size +
    ids.filter((value) => value === undefined).length
  );
}

function quantity(count: number, noun: string, plural = `${noun}s`): string {
  return `${count} ${count === 1 ? noun : plural}`;
}

/** What calls to one kind of HAL-C2 tool did, counting what took effect; failed calls apart. */
export function summarizeHalC2ToolCalls(
  action: HalC2ToolSummaryAction,
  calls: ReadonlyArray<HalC2ToolCall>,
): { label: string; failedCount: number } {
  const results = calls.map((call) => {
    const result = readResult(call.output);
    return {
      input: readInput(call.input),
      output: result.data,
      outcome: result.failed ? ("failed" as const) : call.outcome,
    };
  });
  const completed = results.filter((call) => call.outcome === "completed");
  const failedCount = results.filter((call) => call.outcome === "failed").length;
  const selected = completed.length > 0 ? completed : results;
  const times = quantity(selected.length, "time");
  const phrase = (past: string, infinitive: string, object: string) =>
    `${completed.length > 0 ? past : `Tried to ${infinitive}`} ${object}`;
  const entityIds = (key: string) =>
    selected.map((call) => id(call.output?.[key]) ?? id(call.input?.[key]));
  const counted = (key: string, noun: string, plural?: string) =>
    quantity(countEntities(entityIds(key)), noun, plural);
  const projectIds = selected.map(
    (call) => id(call.output?.id) ?? id(call.output?.projectId) ?? id(call.input?.projectId),
  );
  const threadIds = selected.map(
    (call) =>
      id(call.output?.threadId) ??
      id(asRecord(call.output?.thread)?.threadId) ??
      id(call.input?.threadId),
  );
  const label = (() => {
    switch (action) {
      case "thread-send": {
        const messages = countEntities(selected.map((call) => id(call.output?.messageId)));
        const threads = new Set(threadIds).size;
        const object = threadIds.every((value) => value !== undefined)
          ? messages === threads && messages > 1
            ? `messages to ${quantity(threads, "thread")}`
            : `${quantity(messages, "message")} to ${quantity(threads, "thread")}`
          : quantity(messages, "message");
        return phrase("Sent", "send", object);
      }
      case "thread-create": {
        const created: string[] = [];
        const known =
          completed.length > 0 &&
          completed.every((call) => {
            const threads = Array.isArray(call.output?.threads)
              ? call.output.threads
              : [call.output];
            return threads.every((thread) => {
              const record = asRecord(thread);
              if (record?.status === "rolled_back") return true;
              const threadId = id(record?.threadId);
              if (threadId) created.push(threadId);
              return threadId !== undefined;
            });
          });
        return known
          ? `Created ${quantity(new Set(created).size, "thread")}`
          : `Requested thread creation ${times}`;
      }
      case "delegate":
        return phrase("Delegated", "delegate", counted("taskId", "task"));
      case "thread-read":
      case "thread-wait": {
        const targets = threadIds.every((value) => value !== undefined)
          ? quantity(new Set(threadIds).size, "thread")
          : `threads ${times}`;
        return action === "thread-read"
          ? phrase("Read", "read", targets)
          : phrase("Waited on", "wait on", targets);
      }
      case "thread-list":
        return phrase("Listed", "list", `threads ${times}`);
      case "thread-interrupt":
        return phrase(
          "Requested interrupts for",
          "interrupt",
          quantity(countEntities(threadIds), "thread"),
        );
      case "task-status":
        return phrase("Checked", "check", `task status ${times}`);
      case "task-cancel":
        return phrase("Requested cancellation of", "cancel", counted("taskId", "task"));
      case "schedule-create":
        return phrase("Scheduled", "schedule", counted("scheduledTaskId", "task"));
      case "schedule-list":
        return phrase("Listed", "list", `scheduled tasks ${times}`);
      case "schedule-update":
        return phrase("Updated", "update", counted("scheduledTaskId", "scheduled task"));
      case "schedule-delete":
        // A delete that answered deleted:false was still a request to delete.
        return phrase(
          "Requested deletion of",
          "delete",
          counted("scheduledTaskId", "scheduled task"),
        );
      case "schedule-run":
        return phrase("Requested", "request", quantity(selected.length, "scheduled task run"));
      case "thread-configuration":
        return phrase("Checked", "check", `thread configuration ${times}`);
      case "thread-configure":
        return phrase("Set", "set", `thread model ${times}`);
      case "thread-fork":
        return phrase("Requested", "request", quantity(selected.length, "thread fork"));
      case "thread-merge":
        return phrase("Requested", "request", quantity(selected.length, "context merge"));
      case "thread-search":
        return phrase("Searched", "search", `threads ${times}`);
      case "thread-transfers":
        return phrase("Checked", "check", `thread transfers ${times}`);
      case "thread-organize":
        return phrase("Organized", "organize", `threads ${times}`);
      case "thread-update":
        return phrase("Updated", "update", quantity(countEntities(threadIds), "thread"));
      case "queue-list":
        return phrase("Listed", "list", `queued messages ${times}`);
      case "queue-read":
        return phrase("Read", "read", counted("queuedRunId", "queued message"));
      case "queue-edit":
        return phrase("Edited", "edit", counted("queuedRunId", "queued message"));
      case "queue-cancel":
        return phrase("Requested cancellation of", "cancel", counted("queuedRunId", "queued run"));
      case "queue-reorder":
        return phrase("Reordered", "reorder", counted("queuedRunId", "queued run"));
      case "queue-steer":
        return phrase(
          "Requested steering with",
          "steer with",
          counted("queuedRunId", "queued message"),
        );
      case "question-list":
        return phrase("Listed", "list", `pending questions ${times}`);
      case "question-read":
        return phrase("Read", "read", counted("requestId", "pending question request"));
      case "question-respond":
        return phrase("Answered", "answer", counted("requestId", "pending question request"));
      case "worktree-handoff":
        return phrase("Handed off to", "hand off to", counted("worktreePath", "worktree"));
      case "worktree-list":
        return phrase("Listed", "list", `workspace branches ${times}`);
      case "worktree-status":
        return phrase("Checked", "check", `worktree status ${times}`);
      case "project-list":
        return phrase("Listed", "list", `projects ${times}`);
      case "project-read":
        return phrase("Read", "read", quantity(countEntities(projectIds), "project"));
      case "project-create":
        return phrase("Registered", "register", quantity(countEntities(projectIds), "project"));
      case "project-update":
        return phrase("Updated", "update", quantity(countEntities(projectIds), "project"));
      case "project-delete":
        return phrase("Deleted", "delete", quantity(countEntities(projectIds), "project"));
      case "project-clone":
        return phrase("Cloned", "clone", counted("cwd", "repository", "repositories"));
      case "environment-read":
        return phrase("Checked", "check", `environment preferences ${times}`);
      case "environment-update":
        return phrase("Updated", "update", `environment preferences ${times}`);
      case "attachment-prepare":
        return phrase("Prepared", "prepare", counted("attachmentId", "attachment upload"));
      case "attachment-discard":
        return phrase("Discarded", "discard", counted("attachmentId", "pending attachment"));
      case "attachment-send": {
        // A message can carry several attachments; a retry is the same message.
        const messages = new Map<string, (typeof selected)[number]>();
        selected.forEach((call, index) =>
          messages.set(id(call.output?.messageId) ?? `call-${index}`, call),
        );
        const attachments = (call: (typeof selected)[number]) =>
          Array.isArray(call.input?.attachments) ? call.input.attachments.length : 0;
        const sent = [...messages.values()];
        const total = sent.reduce((count, call) => count + attachments(call), 0);
        const targets = threadIds.every((value) => value !== undefined)
          ? ` to ${quantity(new Set(threadIds).size, "thread")}`
          : "";
        return phrase(
          "Sent",
          "send",
          sent.every((call) => attachments(call) > 0)
            ? `${quantity(total, "attachment")}${targets}`
            : `attachments${targets} ${times}`,
        );
      }
      case "link-pr":
        return phrase("Linked", "link", quantity(selected.length, "pull request"));
      case "unlink-pr":
        return phrase("Unlinked", "unlink", quantity(selected.length, "pull request"));
      case "list-prs":
        return phrase(
          "Checked",
          "check",
          `linked pull requests${selected.length === 1 ? "" : ` ${times}`}`,
        );
      case "browser":
        return phrase("Used", "use", `browser ${times}`);
      case "device":
        return phrase("Used", "use", `device controls ${times}`);
      case "capabilities":
        return phrase("Checked", "check", `orchestration capabilities ${times}`);
    }
  })();
  return { label, failedCount };
}
