import { canSnooze, snoozeWakeLabel } from "@hal-c2/client-runtime/state/thread-settled";
import type {
  ShellSidebarDraft,
  ShellSidebarProject,
  ShellSidebarState,
  ShellSidebarThread,
  ShellSidebarThreadStatus,
} from "@hal-c2/contracts/shell";

import type { OrchestrationShellSnapshot } from "../connection.ts";
import { LIST_PANE_WIDTH } from "../components/ChatView.layout.ts";
import {
  type Row,
  type Selection,
  selectionEquals,
  type SidebarSection,
} from "../components/Sidebar.logic.ts";
import { padClip } from "../format.ts";
import { projectLabel, type TuiThreadShell } from "../orchestrationV2Adapter.ts";
import {
  ansi,
  relativeTime,
  resolveProjectStatus,
  resolveThreadStatus,
  THEME,
  type Palette,
} from "../theme.ts";
import { chunk, styled, type StyledText } from "./styledText.ts";

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
  /** The machine it lives on, when the list spans a cluster. */
  readonly machine: string | null;
  /** Relative age of the row's timestamp ("5m", "2d"). */
  readonly age: string;
  /** Single-cell status dot and its ANSI colour name (`Theme.ansi(name)`). */
  readonly glyph: string;
  readonly glyphColor: string;
}

/** What every list row carries: its painted lines and where it sits in the list. */
interface RowLines {
  /** The row's lines as the OpenTUI client draws them (Sidebar.tsx). */
  readonly lines: ReadonlyArray<StyledText>;
  /** Its first line, counted from the top of the list. */
  readonly top: number;
}

/** One sidebar row, in paint order: a thread (a card when active), a shelf header, "Show more". */
export type TuiSidebarRow = RowLines &
  (
    | {
        readonly kind: "thread";
        readonly key: string;
        readonly selected: boolean;
        readonly thread: TuiSidebarThread;
      }
    | {
        readonly kind: "section";
        readonly key: string;
        readonly selected: boolean;
        readonly section: Exclude<SidebarSection, "active">;
        readonly title: string;
        readonly count: number;
        readonly expanded: boolean;
      }
    | {
        readonly kind: "more";
        readonly key: string;
        readonly selected: boolean;
        readonly hiddenCount: number;
      }
    | {
        readonly kind: "draft";
        readonly key: string;
        readonly selected: boolean;
        readonly draft: ShellSidebarDraft;
        readonly projectName: string;
      }
  );

/** A row before it is placed in the list. */
type UnplacedRow = TuiSidebarRow extends infer Placed
  ? Placed extends TuiSidebarRow
    ? Omit<Placed, "top">
    : never
  : never;

/** One screen line of the list viewport, for the list's `Repeater`. */
export interface TuiSidebarLine {
  readonly kind: TuiSidebarRow["kind"];
  /** The row's key: a thread key, a section id, the more row's or the draft's key. */
  readonly key: string;
  /** The shelf a section header toggles. */
  readonly section: string | null;
  /** Which line of its row this is (an active card has four). */
  readonly part: number;
  readonly text: StyledText;
  /** Inside an active thread's card: padded one cell each side. */
  readonly card: boolean;
  /** The selected card's selection background. */
  readonly highlight: boolean;
}

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
  /** The rows at least partly inside the list viewport. */
  readonly visibleRows: ReadonlyArray<TuiSidebarRow>;
  /** The viewport's lines, scrolled to keep the selection in view. */
  readonly lines: ReadonlyArray<TuiSidebarLine>;
  /** The first line on screen, counted from the top of the list. */
  readonly scrollTop: number;
  /** The list viewport's height in lines. */
  readonly listRows: number;
  /** "All projects" or the scoped project's name. */
  readonly scopeLabel: string;
  /** The project row: "Project <scope> ▾", clipped to the pane. */
  readonly scopeLine: StyledText;
}

export interface TuiSidebarStateInput {
  readonly shell: OrchestrationShellSnapshot | null;
  /** `buildRows` output: already filtered, bucketed and sorted. */
  readonly rows: ReadonlyArray<Row>;
  readonly selectedThreadId: string | null;
  /** The store's selection, when it rests on a shelf header or "Show more". */
  readonly selection?: Selection | null;
  readonly projectScopeId: string | null;
  readonly filter: string;
  readonly now: string;
  /** The server settles threads (`capabilities.threadSettlement`). */
  readonly settlementSupported?: boolean;
  /**
   * An open new-thread draft: no thread row reads as the open one. Only a
   * draft with content (`listed`, the default) gets a row above the threads.
   */
  readonly draft?: {
    readonly draftId: string;
    readonly projectId: string;
    readonly listed?: boolean;
  } | null;
  /** Lines the list can show at once; unbounded when omitted. */
  readonly viewportRows?: number;
  /** The previous scroll offset in lines, kept unless the selection left the view. */
  readonly scrollTop?: number;
  /** Scroll the selection back into view (default); false keeps a wheel-scrolled offset. */
  readonly followSelection?: boolean;
  /** The sidebar's width in cells (the list pane's by default). */
  readonly width?: number;
  readonly palette?: Palette;
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
    machine: thread.machine ?? null,
    age: relativeTime(row.timestamp, Date.parse(now)),
    glyph: status.glyph,
    glyphColor: status.color,
  };
}

/** The lines of one list row, as Sidebar.tsx draws them at `innerWidth` cells. */
function rowLines(
  row: Row,
  selected: boolean,
  innerWidth: number,
  nowMs: number,
  palette: Palette,
): StyledText[] {
  if (row.kind === "section") {
    const fg = row.section === "snoozed" || selected ? palette.accent : palette.dim;
    const count = row.expanded ? "" : ` (${row.count})`;
    return [
      styled(
        chunk(`${selected ? "▌" : " "} ${row.expanded ? "▾" : "▸"} ${row.title}${count} ─`, { fg }),
      ),
    ];
  }
  if (row.kind === "more") {
    return [
      styled(
        chunk(`  ${selected ? "▶" : "+"} Show ${Math.min(row.hiddenCount, 25)} more`, {
          fg: selected ? palette.accent : palette.dim,
        }),
      ),
    ];
  }
  const status = resolveThreadStatus(row.thread);
  const time = relativeTime(row.timestamp, nowMs);
  const marker = chunk(selected ? "▌ " : "  ", { fg: palette.accent });
  const dot = chunk(status.glyph, { fg: ansi(status.color) });
  if (row.section !== "active") {
    const titleBudget = Math.max(1, innerWidth - 4 - time.length - 1);
    return [
      styled(
        marker,
        dot,
        chunk(` ${padClip(row.thread.title, titleBudget)}`, { fg: palette.text }),
        chunk(` ${time}`, { fg: palette.dim }),
      ),
    ];
  }
  const contentWidth = Math.max(6, innerWidth - 2);
  const idle = status.key === "idle";
  const topTrailing = idle ? time : status.label;
  const projectBudget = Math.max(1, contentWidth - 5 - Bun.stringWidth(topTrailing));
  const textBudget = Math.max(1, contentWidth - 2);
  return [
    styled(
      marker,
      dot,
      chunk(` ${padClip(row.projectTitle, projectBudget)} `, { fg: palette.dim }),
      chunk(topTrailing, { fg: idle ? palette.dim : ansi(status.color) }),
    ),
    styled(
      chunk("  ", { fg: palette.text }),
      chunk(padClip(row.thread.title, textBudget), { fg: palette.text, bold: true }),
    ),
    styled(
      row.thread.branch
        ? chunk(`  ${padClip(row.thread.branch, textBudget)}`, { fg: palette.dim })
        : null,
    ),
    styled(),
  ];
}

/** Port of the web's `buildShellSidebarState` onto the TUI's `buildRows`. */
export function buildTuiSidebarState(input: TuiSidebarStateInput): TuiSidebarState {
  const { shell, now } = input;
  const palette = input.palette ?? THEME;
  const nowMs = Date.parse(now);
  const innerWidth = Math.max(8, (input.width ?? LIST_PANE_WIDTH) - 4);
  const draft = input.draft ?? null;
  const selection = input.selection ?? null;
  const byBucket: Record<SidebarSection, TuiSidebarThread[]> = {
    active: [],
    snoozed: [],
    settled: [],
  };
  let settledTotal = 0;
  // With a draft open, no thread row reads as the open one.
  const isSelected = (row: Row) =>
    row.kind === "thread"
      ? !draft && row.id === input.selectedThreadId
      : selectionEquals(selection, row);
  const listed = input.rows.map((row): UnplacedRow => {
    const selected = isSelected(row);
    const lines = rowLines(row, selected, innerWidth, nowMs, palette);
    switch (row.kind) {
      case "thread": {
        const thread = toSidebarThread(row, now, input.settlementSupported ?? true);
        byBucket[row.section].push(thread);
        return { kind: "thread", key: thread.key, selected, thread, lines };
      }
      case "section":
        if (row.section === "settled") settledTotal = row.count;
        return {
          kind: "section",
          key: row.id,
          selected,
          section: row.section,
          title: row.title,
          count: row.count,
          expanded: row.expanded,
          lines,
        };
      case "more":
        return {
          kind: "more",
          key: `${row.id}:more`,
          selected,
          hiddenCount: row.hiddenCount,
          lines,
        };
    }
  });

  const drafts: ShellSidebarDraft[] =
    draft && draft.listed !== false
      ? [{ draftId: draft.draftId, projectKey: projectKey(draft.projectId), label: "New thread" }]
      : [];
  const projectTitle = (id: string) =>
    projectLabel(shell?.projects.find((project) => project.id === id) ?? { title: id });
  const unplaced: UnplacedRow[] = [
    ...drafts.map((entry): UnplacedRow => {
      const projectName = projectTitle(draft!.projectId);
      return {
        kind: "draft",
        key: `draft:${entry.draftId}`,
        selected: true,
        draft: entry,
        projectName,
        lines: [
          styled(
            chunk(padClip(`▌+ ${entry.label} · ${projectName}`, innerWidth), {
              fg: palette.accent,
            }),
          ),
        ],
      };
    }),
    ...listed,
  ];
  let top = 0;
  const rows = unplaced.map((row): TuiSidebarRow => {
    const placed = { ...row, top };
    top += row.lines.length;
    return placed;
  });
  const window = scrollWindow(
    rows,
    input.viewportRows,
    input.scrollTop ?? 0,
    input.followSelection ?? true,
  );

  const scopeLabel =
    input.projectScopeId === null ? "All projects" : projectTitle(input.projectScopeId);
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
    scopeLabel,
    scopeLine: styled(
      chunk("Project ", { fg: palette.dim }),
      chunk(padClip(scopeLabel, Math.max(1, innerWidth - 12)), {
        fg: scopeLabel === "All projects" ? palette.text : palette.accent,
      }),
      chunk(" ▾", { fg: palette.dim }),
    ),
  };
}

/**
 * The list viewport, scrolled like the OpenTUI client's scrollbox: only when
 * the selected row would leave it (to its top edge going up, its bottom edge
 * going down), and never past the end of the list.
 */
export function scrollWindow(
  rows: ReadonlyArray<TuiSidebarRow>,
  viewportRows: number | undefined,
  previousTop: number,
  followSelection = true,
): Pick<TuiSidebarState, "visibleRows" | "lines" | "scrollTop" | "listRows"> {
  const total = rows.reduce((sum, row) => sum + row.lines.length, 0);
  const viewport = viewportRows === undefined ? Math.max(1, total) : Math.max(1, viewportRows);
  let scrollTop = Math.max(0, Math.min(previousTop, total - viewport));
  const selected = followSelection ? rows.find((row) => row.selected) : undefined;
  if (selected) {
    const bottom = selected.top + selected.lines.length;
    if (selected.top < scrollTop) scrollTop = selected.top;
    else if (bottom > scrollTop + viewport) scrollTop = bottom - viewport;
  }
  const end = scrollTop + viewport;
  const visibleRows = rows.filter((row) => row.top < end && row.top + row.lines.length > scrollTop);
  const lines: TuiSidebarLine[] = [];
  for (const row of visibleRows) {
    const card = row.kind === "thread" && row.thread.section === "active";
    row.lines.forEach((text, part) => {
      const at = row.top + part;
      if (at < scrollTop || at >= end) return;
      // The card's padded box is its first three lines; the fourth is a gap.
      const inCard = card && part < 3;
      lines.push({
        kind: row.kind,
        key: row.key,
        section: row.kind === "section" ? row.section : null,
        part,
        text,
        card: inCard,
        highlight: inCard && row.selected,
      });
    });
  }
  return { visibleRows, lines, scrollTop, listRows: viewport };
}
