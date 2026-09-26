import { canSnooze, snoozeWakeLabel } from "@t3tools/client-runtime/state/thread-settled";
import type {
  ShellSidebarState,
  ShellSidebarThread,
  ShellSidebarThreadStatus,
} from "@t3tools/contracts/shell";

import type { OrchestrationShellSnapshot } from "../connection.ts";
import type { Row, SidebarSection } from "../components/Sidebar.logic.ts";
import type { TuiThreadShell } from "../orchestrationV2Adapter.ts";
import { relativeTime, resolveThreadStatus } from "../theme.ts";

/**
 * The TUI talks to one environment, so every key is scoped to this id. It
 * keeps `thread.open { key }` shaped like the desktop shell's
 * `<environmentId>:<threadId>`.
 */
export const TUI_ENVIRONMENT_ID = "local";

export const threadKey = (threadId: string): string => `${TUI_ENVIRONMENT_ID}:${threadId}`;
export const projectKey = (projectId: string): string => `${TUI_ENVIRONMENT_ID}:${projectId}`;

/** `<environmentId>:<id>` back to the id; a bare id passes through. */
export function idFromKey(key: string): string {
  const prefix = `${TUI_ENVIRONMENT_ID}:`;
  return key.startsWith(prefix) ? key.slice(prefix.length) : key;
}

/** A contract row plus what a terminal row paints without more lookups. */
export interface TuiSidebarThread extends ShellSidebarThread {
  readonly section: SidebarSection;
  readonly projectName: string;
  /** Relative age of the row's timestamp ("5m", "2d"). */
  readonly age: string;
  /** Single-cell status dot and its ANSI colour name (`Theme.ansi(name)`). */
  readonly glyph: string;
  readonly glyphColor: string;
}

/** One visible sidebar line, in paint order, for a `Repeater`. */
export type TuiSidebarRow =
  | {
      readonly kind: "thread";
      readonly key: string;
      readonly selected: boolean;
      readonly thread: TuiSidebarThread;
    }
  | {
      readonly kind: "section";
      readonly key: string;
      readonly section: Exclude<SidebarSection, "active">;
      readonly title: string;
      readonly count: number;
      readonly expanded: boolean;
    }
  | { readonly kind: "more"; readonly key: string; readonly hiddenCount: number };

/**
 * Published under `sidebar`: the desktop shell's contract, so shared bricks
 * keep working, plus the flat `rows` the terminal list paints and the filter.
 */
export interface TuiSidebarState extends ShellSidebarState {
  readonly rows: ReadonlyArray<TuiSidebarRow>;
  readonly filter: string;
}

export interface TuiSidebarStateInput {
  readonly shell: OrchestrationShellSnapshot | null;
  /** `buildRows` output: already filtered, bucketed and sorted. */
  readonly rows: ReadonlyArray<Row>;
  readonly selectedThreadId: string | null;
  readonly projectScopeId: string | null;
  readonly filter: string;
  readonly now: string;
}

function sidebarStatus(thread: TuiThreadShell): ShellSidebarThreadStatus {
  switch (resolveThreadStatus(thread).key) {
    case "pending-approval":
      return "approval";
    case "awaiting-input":
      return "input";
    case "plan-ready":
      return "waiting";
    case "working":
    case "connecting":
      return "working";
    case "error":
      return "failed";
    default:
      return "ready";
  }
}

function toSidebarThread(row: Extract<Row, { kind: "thread" }>, now: string): TuiSidebarThread {
  const { thread } = row;
  const status = resolveThreadStatus(thread);
  return {
    key: threadKey(thread.id),
    threadId: thread.id,
    environmentId: TUI_ENVIRONMENT_ID,
    projectKey: projectKey(thread.projectId),
    title: thread.title,
    status: sidebarStatus(thread),
    statusLabel: status.key === "idle" ? null : status.label,
    // The TUI keeps no per-thread visit history, so nothing reads as unseen.
    unread: false,
    branch: thread.branch,
    createdAt: thread.createdAt,
    latestUserMessageAt: thread.latestUserMessageAt,
    updatedAt: thread.updatedAt,
    pinned: thread.pinnedAt != null,
    snoozedUntil: thread.snoozedUntil,
    wakeLabel:
      row.section === "snoozed" && thread.snoozedUntil != null
        ? snoozeWakeLabel(thread.snoozedUntil, { now })
        : null,
    wokeAt: null,
    canSettle: true,
    canSnooze: canSnooze(thread, { now }),
    section: row.section,
    projectName: row.projectTitle,
    age: relativeTime(row.timestamp),
    glyph: status.glyph,
    glyphColor: status.color,
  };
}

/** Port of the web's `buildShellSidebarState` onto the TUI's `buildRows`. */
export function buildTuiSidebarState(input: TuiSidebarStateInput): TuiSidebarState {
  const { shell, now } = input;
  const byBucket: Record<SidebarSection, TuiSidebarThread[]> = {
    active: [],
    snoozed: [],
    settled: [],
  };
  let settledTotal = 0;
  const rows: TuiSidebarRow[] = input.rows.map((row) => {
    switch (row.kind) {
      case "thread": {
        const thread = toSidebarThread(row, now);
        byBucket[row.section].push(thread);
        return {
          kind: "thread",
          key: thread.key,
          selected: row.id === input.selectedThreadId,
          thread,
        };
      }
      case "section":
        if (row.section === "settled") settledTotal = row.count;
        return {
          kind: "section",
          key: row.id,
          section: row.section,
          title: row.title,
          count: row.count,
          expanded: row.expanded,
        };
      case "more":
        return { kind: "more", key: `${row.id}:more`, hiddenCount: row.hiddenCount };
    }
  });

  const threadCount = new Map<string, number>();
  for (const thread of shell?.threads ?? []) {
    if (thread.archivedAt != null) continue;
    threadCount.set(thread.projectId, (threadCount.get(thread.projectId) ?? 0) + 1);
  }
  const projects = (shell?.projects ?? []).map((project) => ({
    key: projectKey(project.id),
    displayName: project.title,
    environmentId: TUI_ENVIRONMENT_ID,
    projectId: project.id as string,
    workspaceRoot: project.workspaceRoot,
    threadCount: threadCount.get(project.id) ?? 0,
  }));

  return {
    projects,
    localEnvironmentId: TUI_ENVIRONMENT_ID,
    localProjects: projects.map((project) => ({
      key: project.key,
      logicalProjectKey: project.key,
      displayName: project.displayName,
      environmentId: project.environmentId,
      projectId: project.projectId,
      workspaceRoot: project.workspaceRoot,
    })),
    scopeProjectKey: input.projectScopeId === null ? null : projectKey(input.projectScopeId),
    // Pinned threads stay in the active list, sorted with it, as the TUI always has.
    pinned: [],
    active: byBucket.active,
    snoozed: byBucket.snoozed,
    settled: byBucket.settled,
    settledTotal,
    drafts: [],
    activeThreadKey: input.selectedThreadId === null ? null : threadKey(input.selectedThreadId),
    activeDraftId: null,
    rows,
    filter: input.filter,
  };
}
