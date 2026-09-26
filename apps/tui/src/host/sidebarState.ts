import { canSnooze, snoozeWakeLabel } from "@t3tools/client-runtime/state/thread-settled";
import type {
  ShellSidebarDraft,
  ShellSidebarProject,
  ShellSidebarState,
  ShellSidebarThread,
  ShellSidebarThreadStatus,
} from "@t3tools/contracts/shell";

import type { OrchestrationShellSnapshot } from "../connection.ts";
import type { Row, SidebarSection } from "../components/Sidebar.logic.ts";
import type { TuiThreadShell } from "../orchestrationV2Adapter.ts";
import { relativeTime, resolveProjectStatus, resolveThreadStatus } from "../theme.ts";

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
  | { readonly kind: "more"; readonly key: string; readonly hiddenCount: number }
  | {
      readonly kind: "draft";
      readonly key: string;
      readonly selected: boolean;
      readonly draft: ShellSidebarDraft;
      readonly projectName: string;
    };

/** A project plus its most urgent thread status (null glyph when every thread is idle). */
export interface TuiSidebarProject extends ShellSidebarProject {
  readonly glyph: string | null;
  readonly glyphColor: string | null;
  readonly statusLabel: string | null;
}

/**
 * Published under `sidebar`: the desktop shell's contract, so shared bricks
 * keep working, plus the flat `rows` the terminal list paints and the filter.
 */
export interface TuiSidebarState extends ShellSidebarState {
  readonly projects: ReadonlyArray<TuiSidebarProject>;
  readonly rows: ReadonlyArray<TuiSidebarRow>;
  readonly filter: string;
  /** The slice of `rows` that fits the list's height, scrolled to keep the selection in view. */
  readonly visibleRows: ReadonlyArray<TuiSidebarRow>;
  /** Index into `rows` of the first visible row. */
  readonly scrollTop: number;
  /** Rows hidden above and below the visible slice. */
  readonly hiddenAbove: number;
  readonly hiddenBelow: number;
  /** "All projects" or the scoped project's name. */
  readonly scopeLabel: string;
}

export interface TuiSidebarStateInput {
  readonly shell: OrchestrationShellSnapshot | null;
  /** `buildRows` output: already filtered, bucketed and sorted. */
  readonly rows: ReadonlyArray<Row>;
  readonly selectedThreadId: string | null;
  readonly projectScopeId: string | null;
  readonly filter: string;
  readonly now: string;
  /** The server settles threads (`capabilities.threadSettlement`). */
  readonly settlementSupported?: boolean;
  /** An open new-thread draft, listed above the threads. */
  readonly draft?: { readonly draftId: string; readonly projectId: string } | null;
  /** Rows the list can show at once; unbounded when omitted. */
  readonly viewportRows?: number;
  /** The previous scroll offset, kept unless the selection left the view. */
  readonly scrollTop?: number;
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

function toSidebarThread(
  row: Extract<Row, { kind: "thread" }>,
  now: string,
  canSettle: boolean,
): TuiSidebarThread {
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
    canSettle,
    canSnooze: canSnooze(thread, { now }),
    section: row.section,
    projectName: row.projectTitle,
    age: relativeTime(row.timestamp, Date.parse(now)),
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
  const listed: TuiSidebarRow[] = input.rows.map((row) => {
    switch (row.kind) {
      case "thread": {
        const thread = toSidebarThread(row, now, input.settlementSupported ?? true);
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

  const draft = input.draft ?? null;
  const drafts: ShellSidebarDraft[] = draft
    ? [{ draftId: draft.draftId, projectKey: projectKey(draft.projectId), label: "New thread" }]
    : [];
  const projectTitle = (id: string) =>
    shell?.projects.find((project) => project.id === id)?.title ?? id;
  const rows: TuiSidebarRow[] = [
    ...drafts.map((entry): TuiSidebarRow => ({
      kind: "draft",
      key: `draft:${entry.draftId}`,
      selected: true,
      draft: entry,
      projectName: projectTitle(draft!.projectId),
    })),
    // With a draft open, no thread row reads as the open one.
    ...(draft
      ? listed.map((row) => (row.kind === "thread" ? { ...row, selected: false } : row))
      : listed),
  ];
  const window = scrollWindow(rows, input.viewportRows, input.scrollTop ?? 0);

  const threadCount = new Map<string, number>();
  for (const thread of shell?.threads ?? []) {
    if (thread.archivedAt != null) continue;
    threadCount.set(thread.projectId, (threadCount.get(thread.projectId) ?? 0) + 1);
  }
  const projects = (shell?.projects ?? []).map((project): TuiSidebarProject => {
    const status = resolveProjectStatus(
      (shell?.threads ?? []).filter(
        (thread) => thread.projectId === project.id && thread.archivedAt == null,
      ),
    );
    return {
      key: projectKey(project.id),
      displayName: project.title,
      environmentId: TUI_ENVIRONMENT_ID,
      projectId: project.id as string,
      workspaceRoot: project.workspaceRoot,
      threadCount: threadCount.get(project.id) ?? 0,
      glyph: status?.glyph ?? null,
      glyphColor: status?.color ?? null,
      statusLabel: status?.label ?? null,
    };
  });

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
    drafts,
    activeThreadKey:
      draft || input.selectedThreadId === null ? null : threadKey(input.selectedThreadId),
    activeDraftId: draft?.draftId ?? null,
    rows,
    filter: input.filter,
    ...window,
    scopeLabel: input.projectScopeId === null ? "All projects" : projectTitle(input.projectScopeId),
  };
}

/**
 * Keep the selected row inside a `viewportRows`-tall window: scroll only when
 * the selection would leave it, and never past the end of the list.
 */
export function scrollWindow(
  rows: ReadonlyArray<TuiSidebarRow>,
  viewportRows: number | undefined,
  previousTop: number,
): Pick<TuiSidebarState, "visibleRows" | "scrollTop" | "hiddenAbove" | "hiddenBelow"> {
  const viewport = viewportRows === undefined ? rows.length : Math.max(1, viewportRows);
  let top = Math.max(0, Math.min(previousTop, rows.length - viewport));
  const selected = rows.findIndex((row) => "selected" in row && row.selected);
  if (selected >= 0) {
    if (selected < top) top = selected;
    else if (selected >= top + viewport) top = selected - viewport + 1;
  }
  const visibleRows = rows.slice(top, top + viewport);
  return {
    visibleRows,
    scrollTop: top,
    hiddenAbove: top,
    hiddenBelow: Math.max(0, rows.length - top - visibleRows.length),
  };
}
