export type HalC2McpToolLogo = "hal-c2";

export interface HalC2McpToolPresentation {
  readonly displayName: string;
  readonly logo: HalC2McpToolLogo;
}

export type HalC2McpToolSummaryAction =
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

export interface HalC2McpToolDefinition {
  readonly displayName: string;
  readonly labels: readonly [action: string, running: string, completed: string, detail: string];
  readonly icon: "hal-c2" | "browser" | "device" | "pull-request";
  readonly summaryAction: HalC2McpToolSummaryAction;
}

function tool(
  labels: HalC2McpToolDefinition["labels"],
  summaryAction: HalC2McpToolSummaryAction,
  icon: HalC2McpToolDefinition["icon"] = "hal-c2",
  displayName = `${labels[0]} ${labels[3]}`,
): HalC2McpToolDefinition {
  return { displayName, labels, icon, summaryAction };
}

const HALC2_MCP_SERVER_ALIASES = new Set(["hal-c2", "hal_c2", "halc2"]);

// Cards, activity rows, summaries, and provider identity recovery share this inventory.
const HALC2_MCP_TOOLS: Readonly<Record<string, HalC2McpToolDefinition>> = {
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
  halc2_thread_start: tool(["Start", "Starting", "Started", "a HAL-C2 thread"], "thread-create"),
  halc2_thread_list: tool(["List", "Listing", "Listed", "HAL-C2 threads"], "thread-list"),
  halc2_thread_read: tool(["Read", "Reading", "Read", "a HAL-C2 thread"], "thread-read"),
  halc2_thread_send: tool(["Send", "Sending", "Sent", "to a HAL-C2 thread"], "thread-send"),
  halc2_thread_wait: tool(["Wait", "Waiting", "Waited", "for a HAL-C2 thread"], "thread-wait"),
  halc2_thread_interrupt: tool(
    ["Interrupt", "Interrupting", "Requested an interrupt of", "a HAL-C2 thread"],
    "thread-interrupt",
  ),
  halc2_worktree_handoff: tool(
    ["Hand off", "Handing off", "Handed off", "thread to a git worktree"],
    "worktree-handoff",
  ),
  halc2_worktree_status: tool(
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
  halc2_queue_list: tool(["List", "Listing", "Listed", "queued messages"], "queue-list"),
  halc2_queue_read: tool(["Read", "Reading", "Read", "a queued message"], "queue-read"),
  halc2_queue_edit: tool(["Edit", "Editing", "Edited", "a queued message"], "queue-edit"),
  halc2_queue_cancel: tool(
    ["Cancel", "Canceling", "Requested cancellation of", "a queued run"],
    "queue-cancel",
  ),
  halc2_queue_reorder: tool(
    ["Reorder", "Reordering", "Reordered", "a queued run"],
    "queue-reorder",
  ),
  halc2_queue_promote_to_steer: tool(
    ["Steer with", "Steering with", "Requested steering with", "a queued message"],
    "queue-steer",
  ),
  halc2_pending_request_list: tool(
    ["List", "Listing", "Listed", "pending questions"],
    "question-list",
  ),
  halc2_pending_request_read: tool(
    ["Read", "Reading", "Read", "pending questions"],
    "question-read",
  ),
  halc2_pending_request_respond: tool(
    ["Answer", "Answering", "Answered", "pending questions"],
    "question-respond",
  ),
  halc2_thread_configuration: tool(
    ["Read", "Reading", "Read", "thread configuration"],
    "thread-configuration",
  ),
  halc2_thread_configure: tool(["Set", "Setting", "Set", "thread model"], "thread-configure"),
  halc2_thread_fork: tool(["Fork", "Forking", "Requested a fork of", "this thread"], "thread-fork"),
  halc2_thread_merge_back: tool(
    ["Merge", "Merging", "Requested a merge of", "thread context"],
    "thread-merge",
  ),
  halc2_thread_search: tool(["Search", "Searching", "Searched", "thread content"], "thread-search"),
  halc2_thread_transfers: tool(["Read", "Reading", "Read", "thread transfers"], "thread-transfers"),
  halc2_thread_organize: tool(
    ["Organize", "Organizing", "Organized", "a thread"],
    "thread-organize",
  ),
  halc2_thread_update: tool(
    ["Update", "Updating", "Updated", "HAL-C2 thread metadata"],
    "thread-update",
  ),
  halc2_worktree_list: tool(["List", "Listing", "Listed", "workspace branches"], "worktree-list"),
  halc2_preview_list: tool(["List", "Listing", "Listed", "preview tabs"], "browser", "browser"),
  halc2_preview_close: tool(["Close", "Closing", "Closed", "a preview tab"], "browser", "browser"),
  halc2_environment_read: tool(
    ["Read", "Reading", "Read", "environment preferences"],
    "environment-read",
  ),
  halc2_environment_preferences_update: tool(
    ["Update", "Updating", "Updated", "environment preferences"],
    "environment-update",
  ),
  halc2_thread_launch: tool(
    ["Launch", "Launching", "Launched", "a project thread"],
    "thread-create",
  ),
  halc2_project_list: tool(["List", "Listing", "Listed", "projects"], "project-list"),
  halc2_project_read: tool(["Read", "Reading", "Read", "a project"], "project-read"),
  halc2_project_create: tool(
    ["Register", "Registering", "Registered", "a project"],
    "project-create",
  ),
  halc2_project_update: tool(["Update", "Updating", "Updated", "a project"], "project-update"),
  halc2_project_delete: tool(["Delete", "Deleting", "Deleted", "a project"], "project-delete"),
  halc2_project_clone: tool(["Clone", "Cloning", "Cloned", "a repository"], "project-clone"),
  halc2_attachment_prepare_upload: tool(
    ["Prepare", "Preparing", "Prepared", "an attachment upload"],
    "attachment-prepare",
  ),
  halc2_attachment_discard: tool(
    ["Discard", "Discarding", "Discarded", "a pending attachment"],
    "attachment-discard",
  ),
  halc2_thread_send_attachments: tool(
    ["Send", "Sending", "Sent", "attachments"],
    "attachment-send",
  ),
};

/**
 * The HAL-C2 orchestration tool inventory, used to gate loose name matching on
 * both the server (ACP MCP identity recovery) and the client (logo branding).
 */
export const HALC2_MCP_TOOL_NAMES: ReadonlySet<string> = new Set(Object.keys(HALC2_MCP_TOOLS));

function normalizeHalC2McpToolLabel(value: string): string {
  return value.replace(/\s+(?:complete|completed)\s*$/i, "").trim();
}

/**
 * ACP agents disagree on how the injected HAL-C2 server prefixes its tools:
 * `mcp__hal-c2__x` (Claude/Cursor), `hal-c2.x` (Codex), plus single
 * underscore, colon, slash, dash, and space separators seen from registry
 * agents. The prefix match is deliberately loose because the display-name
 * inventory is the real gate; unknown tools stay on the generic renderer.
 */
function resolveHalC2McpToolName(value: string): string | null {
  const label = normalizeHalC2McpToolLabel(value);
  const mcpMatch = /^mcp__(?<server>.+?)__(?<tool>.+)$/i.exec(label);
  if (mcpMatch?.groups) {
    const { server, tool } = mcpMatch.groups;
    return server !== undefined &&
      tool !== undefined &&
      HALC2_MCP_SERVER_ALIASES.has(server.toLowerCase())
      ? tool
      : null;
  }

  const namespaceMatch = /^(?<server>hal-c2|hal_c2|halc2)(?:[.:/]|\s*·\s*)(?<tool>.+)$/i.exec(
    label,
  );
  if (namespaceMatch?.groups) {
    return namespaceMatch.groups.tool ?? null;
  }

  const prefixed = /^(?:mcp[-_]{1,2})?hal[-_ ]?c2(?:__|[-_.:/ ])(?<tool>.+)$/i.exec(label);
  // Tool names start with `halc2_` themselves, so a bare tool name also parses
  // as a prefixed one; accept whichever reading names a known tool.
  const prefixedTool = prefixed?.groups?.tool;
  if (prefixedTool !== undefined && Object.hasOwn(HALC2_MCP_TOOLS, prefixedTool)) {
    return prefixedTool;
  }
  return Object.hasOwn(HALC2_MCP_TOOLS, label) ? label : null;
}

export function resolveHalC2McpToolDefinition(
  toolName: string | null | undefined,
): HalC2McpToolDefinition | null {
  const name = toolName == null ? null : resolveHalC2McpToolName(toolName);
  return name !== null && Object.hasOwn(HALC2_MCP_TOOLS, name) ? HALC2_MCP_TOOLS[name]! : null;
}

export function resolveHalC2McpToolPresentation(
  toolName: string | null | undefined,
): HalC2McpToolPresentation | null {
  const definition = resolveHalC2McpToolDefinition(toolName);
  return definition === null ? null : { displayName: definition.displayName, logo: "hal-c2" };
}

export function resolveHalC2McpToolSummaryAction(
  toolName: string | null | undefined,
): HalC2McpToolSummaryAction | null {
  return resolveHalC2McpToolDefinition(toolName)?.summaryAction ?? null;
}
