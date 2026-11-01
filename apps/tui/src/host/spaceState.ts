// Spaces and their pages (^X p, palette → Spaces), host side. The pane takes the
// conversation's place like the file browser, at one of three levels: the Spaces,
// one Space's page tree with its trash, and one page's blocks with their comments.
// Everything shown comes from the MC's streams (`spaces`, `space:<id>`), so an edit
// from another client or an agent shows as it lands; the keys only send `space.*`
// RPCs. A page's history (h) is the exception: it is not on a stream, so it is asked
// for while it is open, again when the Space's stream moves. The SpaceView brick
// paints `space` and dispatches `space.*`.
import {
  SPACES_STREAM_ID,
  type Space,
  type SpaceAuthor,
  type SpaceBlock,
  type SpaceBlockKind,
  type SpaceComment,
  type SpaceId,
  type SpacePage,
  type SpacePageAgent,
  type SpacePageHistoryResult,
  type SpacePageVersion,
  type SpacePageVersionContent,
  spaceStreamId,
  WS_METHODS,
} from "@hal-c2/contracts";
import {
  EMPTY_STREAM_ENTITIES,
  entitiesOf,
  type EntityStreamFrame,
  foldStreamEntities,
  type StreamEntities,
} from "@hal-c2/client-runtime/state/stream-entities";

import type { TuiClient } from "../connection.ts";
import { clip } from "../format.ts";
import type { StatusKind } from "../store.ts";
import { type Palette, THEME } from "../theme.ts";
import type { AskSpec } from "./askState.ts";
import type { PickRequest } from "./composerState.ts";
import { wrapWords } from "./settingsSections.ts";
import { chunk, styled, type StyledText } from "./styledText.ts";

/** Rows the pane's border and header take. */
export const SPACE_CHROME_ROWS = 3;

export type TuiSpaceView = "spaces" | "pages" | "page" | "history" | "version";

export interface TuiSpaceRow {
  /**
   * `space:<id>`, `page:<id>`, `trash:<id>`, `block:<id>`, `comment:<id>`, `version:<n>`,
   * `more:more`; a wrapped block repeats its key.
   */
  readonly key: string;
  readonly kind: "space" | "page" | "trashed" | "block" | "comment" | "version" | "more" | "label";
  /** The row as drawn, plain (steps read it). */
  readonly text: string;
  readonly line: StyledText;
  readonly selected: boolean;
  /** A page's depth in the tree. */
  readonly depth?: number;
  readonly blockKind?: SpaceBlockKind;
  readonly checked?: boolean;
  readonly resolved?: boolean;
  /** The first line of an entry (a wrapped block's later lines are false). */
  readonly first: boolean;
}

/** Published under `space`. */
export interface TuiSpaceState {
  readonly open: boolean;
  readonly view: TuiSpaceView;
  /**
   * The header: `spaces`, `space · Research`, `page · Roadmap`, `history · Roadmap`,
   * `version · Roadmap · <when>`, in accent; then the keys, dimmed.
   */
  readonly title: string;
  readonly hint: string;
  readonly status: "loading" | "ready" | "error";
  /** The body line when there are no rows (loading, empty, the stream's refusal). */
  readonly message: string;
  /** The rows that fit, windowed around the selection. */
  readonly rows: ReadonlyArray<TuiSpaceRow>;
}

export interface SpaceControllerOptions {
  readonly client: Pick<TuiClient, "mcCall" | "subscribeMcStream">;
  readonly height: () => number;
  readonly width: () => number;
  readonly palette?: Palette;
  readonly setOpen: (open: boolean) => void;
  readonly publish: (state: TuiSpaceState) => void;
  readonly status: (text: string, kind?: StatusKind) => void;
  /** A one-line question in the prompt's place. */
  readonly ask: (spec: AskSpec) => void;
  /** A picker over the pane. */
  readonly menu: (spec: PickRequest) => void;
  /** Put text on the clipboard; false when the terminal cannot. */
  readonly copy?: (text: string) => boolean;
  /** Read a Markdown file on this machine to import it. */
  readonly readLocalText?: (path: string) => Promise<string>;
  /** The threads a page can be made from, and whose names show on agents' edits. */
  readonly threads: () => ReadonlyArray<{ readonly id: string; readonly title: string }>;
  /** The selected thread, offered first when making a page from a thread. */
  readonly currentThreadId?: () => string | null;
  /** Leave the pane for a thread: the one a page's agent runs in. */
  readonly openThread: (threadId: string) => void;
}

export interface SpaceController {
  /** Handles a `space.*` action; false when it is not one. */
  readonly dispatch: (action: string, payload: unknown) => boolean;
  readonly close: () => void;
  readonly isOpen: () => boolean;
  readonly mode: () => "space";
  /** Republish after a resize or a theme change. */
  readonly sync: () => void;
  readonly commands: () => ReadonlyArray<{ readonly title: string; readonly action: string }>;
  /** Resolves once the RPCs in flight have answered. */
  readonly settled: () => Promise<void>;
  readonly dispose: () => void;
}

const CLOSED: TuiSpaceState = {
  open: false,
  view: "spaces",
  title: "",
  hint: "",
  status: "loading",
  message: "",
  rows: [],
};

const HINTS: Record<TuiSpaceView, string> = {
  spaces: "  ⏎ open · n new · e rename · d delete · esc close",
  pages:
    "  ⏎ open · n new · a subpage · e rename · m move · d trash · r restore · D delete · i import · t from thread · h history · esc back",
  page: "  ⏎ edit · n add · c comment · x tick/resolve · m move · d delete · l link · y copy · h history · g ask an agent · esc back",
  history: "  ⏎ read · r restore · esc back",
  version: "  r restore · esc back",
};

/** The most of an agent's request and error the page repeats; its thread has them whole. */
const AGENT_REQUEST_MOST = 60;
const AGENT_ERROR_MOST = 200;

/** How many versions a look at the history starts with, and the most a refresh asks for again. */
const HISTORY_STRETCH = 30;
const HISTORY_MOST = 100;
/** How long after the Space's stream moves an open history asks again. */
const HISTORY_REFRESH_MS = 1000;

/** The open page's versions, as far back as the user has looked. */
interface PageHistory {
  readonly pageId: string;
  versions: ReadonlyArray<SpacePageVersion>;
  nextBefore: number | null;
  loading: boolean;
  failed: boolean;
}

/** A moment on the machine's clock, to the minute. */
function when(iso: string): string {
  const at = new Date(iso);
  const two = (value: number) => String(value).padStart(2, "0");
  return `${at.getFullYear()}-${two(at.getMonth() + 1)}-${two(at.getDate())} ${two(at.getHours())}:${two(at.getMinutes())}`;
}

const BLOCK_KINDS: ReadonlyArray<{ readonly kind: SpaceBlockKind; readonly label: string }> = [
  { kind: "paragraph", label: "Paragraph" },
  { kind: "heading", label: "Heading" },
  { kind: "checklist", label: "Checklist item" },
  { kind: "callout", label: "Callout" },
  { kind: "subpage_link", label: "Link to a subpage" },
];

/** The contract error a refused RPC carries, wherever the client put it. */
function refusal(error: unknown): {
  readonly tag: string | null;
  readonly reason: string | null;
  readonly message: string;
} {
  type Detail = { readonly _tag?: unknown; readonly reason?: unknown; readonly message?: unknown };
  const failure = error as {
    readonly detail?: Detail;
    readonly cause?: { readonly detail?: Detail };
  };
  const detail = failure?.detail ?? failure?.cause?.detail;
  const message =
    typeof detail?.message === "string"
      ? detail.message
      : error instanceof Error
        ? error.message
        : String(error);
  return {
    tag: typeof detail?._tag === "string" ? detail._tag : null,
    reason: typeof detail?.reason === "string" ? detail.reason : null,
    message,
  };
}

/** What the status line says when a page could not be written from a thread. */
export function refusalText(error: unknown): string {
  const { tag, reason, message } = refusal(error);
  if (tag === "SpaceTextGenerationError") {
    return reason === "unavailable"
      ? `Text generation is unavailable, so no page was made: ${message}`
      : `Text generation failed, so no page was made: ${message}`;
  }
  return message;
}

const byOrder = (a: SpaceBlock, b: SpaceBlock) =>
  a.order < b.order ? -1 : a.order > b.order ? 1 : 0;

export function createSpaceController(options: SpaceControllerOptions): SpaceController {
  const { client } = options;
  const palette = options.palette ?? THEME;
  let open = false;
  let view: TuiSpaceView = "spaces";
  let spaces: StreamEntities = EMPTY_STREAM_ENTITIES;
  let spacesError: string | null = null;
  let unsubscribeSpaces: (() => void) | null = null;
  let spaceId: string | null = null;
  let space: StreamEntities = EMPTY_STREAM_ENTITIES;
  let spaceError: string | null = null;
  let unsubscribeSpace: (() => void) | null = null;
  let pageId: string | null = null;
  // The selected entry per level, by row key, so the selection stays put as rows come and go.
  const selected: Record<TuiSpaceView, string | null> = {
    spaces: null,
    pages: null,
    page: null,
    history: null,
    version: null,
  };
  // The last selected index per level: where the selection lands when its row goes away.
  const selectedIndex: Record<TuiSpaceView, number> = {
    spaces: 0,
    pages: 0,
    page: 0,
    history: 0,
    version: 0,
  };
  let top = 0;
  // Bumped whenever the open Space or page changes (or the pane closes): a reply
  // that would navigate only does so while its generation is current.
  let generation = 0;
  const pending = new Set<Promise<unknown>>();
  let history: PageHistory | null = null;
  let reading: SpacePageVersionContent | null = null;
  // Bumped when the history closes, and when a read is superseded: a late reply is dropped.
  let historyAsked = 0;
  let readAsked = 0;
  // One history request at a time; a refresh asked for meanwhile goes after it.
  let askAgain = false;
  let historyTimer: ReturnType<typeof setTimeout> | null = null;

  const track = <T>(promise: Promise<T>): Promise<T> => {
    pending.add(promise);
    const done = () => pending.delete(promise);
    promise.then(done, done);
    return promise;
  };

  const call = <T>(method: string, payload: unknown): Promise<T> =>
    track(client.mcCall<T>(method, payload));

  // --- what the streams hold ---

  const spaceList = (): Space[] => entitiesOf(spaces, "space") as unknown as Space[];
  const currentSpace = (): Space | undefined => spaceList().find((s) => s.id === spaceId);
  const pages = (): SpacePage[] => entitiesOf(space, "page") as unknown as SpacePage[];
  const pageById = (id: string | null) => pages().find((page) => page.id === id);
  const blocksOf = (id: string): SpaceBlock[] =>
    (entitiesOf(space, "block") as unknown as SpaceBlock[])
      .filter((block) => block.pageId === id)
      .toSorted(byOrder);
  const commentsOf = (id: string): SpaceComment[] =>
    (entitiesOf(space, "comment") as unknown as SpaceComment[]).filter(
      (comment) => comment.pageId === id,
    );

  /** Neither the page nor a page above it is in the trash. */
  const isLive = (page: SpacePage): boolean => {
    const seen = new Set<string>();
    let current: SpacePage | undefined = page;
    while (current) {
      if (current.trashedAt !== null) return false;
      if (current.parentPageId === null || seen.has(current.parentPageId)) return true;
      seen.add(current.id);
      current = pageById(current.parentPageId);
    }
    return true;
  };

  /** The live pages depth first, each with its depth. */
  const liveTree = (): Array<{ readonly page: SpacePage; readonly depth: number }> => {
    const live = pages().filter(isLive);
    const ids = new Set(live.map((page) => page.id));
    const out: Array<{ page: SpacePage; depth: number }> = [];
    const walk = (parent: string | null, depth: number) => {
      for (const page of live) {
        const atTop = page.parentPageId === null || !ids.has(page.parentPageId);
        if (parent === null ? atTop : page.parentPageId === parent) {
          out.push({ page, depth });
          walk(page.id, depth + 1);
        }
      }
    };
    walk(null, 0);
    return out;
  };

  const trashed = (): SpacePage[] => pages().filter((page) => page.trashedAt !== null);

  const agentOfPage = (id: string | null) =>
    (entitiesOf(space, "pageAgent") as unknown as SpacePageAgent[]).find(
      (agent) => agent.pageId === id,
    );
  const threadTitle = (threadId: string) =>
    options.threads().find((thread) => thread.id === threadId)?.title ?? "an agent";

  const agentOf = (block: SpaceBlock): string | null => {
    const author: SpaceAuthor =
      block.updatedBy.type === "agent" ? block.updatedBy : block.createdBy;
    return author.type === "agent" ? threadTitle(author.threadId) : null;
  };

  // --- rows ---

  const width = () => Math.max(10, options.width() - 4);

  const marker = (active: boolean) => (active ? "▸ " : "  ");

  const entryRow = (
    key: string,
    kind: TuiSpaceRow["kind"],
    text: string,
    extra: Partial<TuiSpaceRow> = {},
    fg = palette.text,
  ): TuiSpaceRow => {
    const active = selected[view] === key;
    const drawn = clip(`${marker(active)}${text}`, width());
    const bg = active ? { bg: palette.selectedBg } : {};
    return {
      key,
      kind,
      text: drawn,
      line: styled(chunk(drawn, { fg: active ? palette.text : fg, ...bg, ...extra.line })),
      selected: active,
      first: true,
      ...extra,
    } as TuiSpaceRow;
  };

  const label = (text: string): TuiSpaceRow => ({
    key: `label:${text}`,
    kind: "label",
    text,
    line: styled(chunk(text, { fg: palette.accent, bold: true })),
    selected: false,
    first: true,
  });

  const blockRows = (block: SpaceBlock): TuiSpaceRow[] => {
    const key = `block:${block.id}`;
    const active = selected[view] === key;
    const linked = block.kind === "subpage_link" ? pageById(block.linkedPageId) : undefined;
    const prefix =
      block.kind === "checklist"
        ? block.checked
          ? "[x] "
          : "[ ] "
        : block.kind === "callout"
          ? "▌ "
          : block.kind === "subpage_link"
            ? "↳ "
            : "";
    const body =
      block.kind === "subpage_link"
        ? (linked?.title ?? (block.text || "(a deleted page)"))
        : block.text;
    const agent = agentOf(block);
    const room = width() - 2 - Bun.stringWidth(prefix);
    const lines = wrapWords(body === "" ? " " : body, room);
    const fg =
      block.kind === "heading" || block.kind === "subpage_link"
        ? palette.accent
        : block.kind === "callout"
          ? palette.warning
          : block.kind === "checklist" && block.checked
            ? palette.dim
            : palette.text;
    const bg = active ? { bg: palette.selectedBg } : {};
    return lines.map((text, index) => {
      const first = index === 0;
      const last = index === lines.length - 1;
      const lead = first
        ? `${marker(active)}${prefix}`
        : `  ${" ".repeat(Bun.stringWidth(prefix))}`;
      const by = last && agent ? `  · ${agent}` : "";
      return {
        key,
        kind: "block",
        text: `${lead}${text}${by}`,
        line: styled(
          chunk(lead, { fg: palette.dim, ...bg }),
          chunk(text, { fg, bold: block.kind === "heading", ...bg }),
          by !== "" && chunk(by, { fg: palette.faint, ...bg }),
        ),
        selected: active,
        blockKind: block.kind,
        checked: block.checked,
        first,
      } satisfies TuiSpaceRow;
    });
  };

  const commentRow = (comment: SpaceComment, note = ""): TuiSpaceRow => {
    const key = `comment:${comment.id}`;
    const active = selected.page === key;
    const resolved = comment.resolvedAt !== null;
    const author =
      comment.author.type === "agent" ? `${threadTitle(comment.author.threadId)}: ` : "";
    const text = clip(
      `${marker(active)}  ┊ ${resolved ? "✓ " : ""}${author}${comment.body}${resolved ? " (resolved)" : ""}${note}`,
      width(),
    );
    const bg = active ? { bg: palette.selectedBg } : {};
    return {
      key,
      kind: "comment",
      text,
      line: styled(chunk(text, { fg: resolved ? palette.faint : palette.dim, ...bg })),
      selected: active,
      resolved,
      first: true,
    };
  };

  const versionRow = (entry: SpacePageVersion, newest: boolean): TuiSpaceRow => {
    const by = entry.author.type === "agent" ? (entry.threadTitle ?? "an agent") : "You";
    const current = newest ? " · current" : "";
    const source = entry.restoredFromAt ? ` · restored from ${when(entry.restoredFromAt)}` : "";
    return entryRow(
      `version:${entry.version}`,
      "version",
      `${when(entry.at)}  ${by}${current}${source}`,
    );
  };

  /** Every row of the open level, before the selection is applied. */
  const allRows = (): TuiSpaceRow[] => {
    if (view === "spaces") {
      return spaceList().map((entry) => entryRow(`space:${entry.id}`, "space", entry.name));
    }
    if (view === "pages") {
      const rows = liveTree().map(({ page, depth }) =>
        entryRow(`page:${page.id}`, "page", `${"  ".repeat(depth)}${page.title}`, { depth }),
      );
      const bin = trashed();
      if (bin.length > 0) {
        rows.push(label("Trash"));
        for (const page of bin) {
          rows.push(entryRow(`trash:${page.id}`, "trashed", page.title, {}, palette.dim));
        }
      }
      return rows;
    }
    if (view === "history") {
      const rows = (history?.versions ?? []).map((entry, index) => versionRow(entry, index === 0));
      if (history?.nextBefore != null) rows.push(entryRow("more:more", "more", "Load more…"));
      return rows;
    }
    if (view === "version") {
      return (reading?.blocks ?? []).flatMap((block) => blockRows(block));
    }
    const id = pageId;
    if (id === null) return [];
    const comments = commentsOf(id);
    const blocks = blocksOf(id);
    const rows: TuiSpaceRow[] = [];
    for (const block of blocks) {
      rows.push(...blockRows(block));
      for (const comment of comments.filter((entry) => entry.blockId === block.id)) {
        rows.push(commentRow(comment));
      }
    }
    const onPage = comments.filter((comment) => comment.blockId === null);
    // A restore can take a block away and leave its comments, until it comes back.
    const orphaned = comments.filter(
      (comment) =>
        comment.blockId !== null && !blocks.some((block) => block.id === comment.blockId),
    );
    if (onPage.length + orphaned.length > 0) {
      rows.push(label("Comments"));
      for (const comment of onPage) rows.push(commentRow(comment));
      for (const comment of orphaned) {
        rows.push(commentRow(comment, " · on a block no longer on this page"));
      }
    }
    return rows;
  };

  /** The keys that can be selected, in order. */
  const entryKeys = (rows: ReadonlyArray<TuiSpaceRow>): string[] =>
    rows.filter((row) => row.kind !== "label" && row.first).map((row) => row.key);

  /** Keep the selection on an entry that exists: its own, else the one at its last index. */
  const settleSelection = () => {
    const keys = entryKeys(allRows());
    const current = selected[view];
    const index = current === null ? -1 : keys.indexOf(current);
    if (index >= 0) {
      selectedIndex[view] = index;
      return;
    }
    selected[view] = keys[Math.min(selectedIndex[view], keys.length - 1)] ?? null;
    selectedIndex[view] = Math.max(0, keys.indexOf(selected[view] ?? ""));
  };

  const selectedEntry = (): { readonly kind: string; readonly id: string } | null => {
    const key = selected[view];
    if (key === null) return null;
    const at = key.indexOf(":");
    return { kind: key.slice(0, at), id: key.slice(at + 1) };
  };

  // --- publishing ---

  const titleText = (): string => {
    if (view === "spaces") return "spaces";
    const name = currentSpace()?.name ?? "";
    if (view === "pages") return `space · ${name}`;
    const page = pageById(pageId);
    if (view === "history") return `history · ${page?.title ?? ""}`;
    if (view === "version") {
      return `version · ${reading?.title ?? ""} · ${reading ? when(reading.at) : ""}`;
    }
    const from = page?.sourceThreadId ? ` · from ${threadTitle(page.sourceThreadId)}` : "";
    const bin = page && !isLive(page) ? " · in the trash" : "";
    return `page · ${page?.title ?? ""}${from}${bin}`;
  };

  /** What the open page says about its agent, and the keys that go with it. */
  const agentText = (agent: SpacePageAgent): string => {
    const title = options.threads().find((thread) => thread.id === agent.threadId)?.title;
    const open = `o opens ${title ? `“${title}”` : "its thread"}`;
    switch (agent.status) {
      case "running":
        return `An agent is working on “${clip(agent.request, AGENT_REQUEST_MOST)}” · s stops · ${open}`;
      case "stopping":
        return `Stopping the agent… · ${open}`;
      case "completed":
        return `The agent finished ${agent.edited ? "and changed" : "without changing"} this page. · ${open} · z clears`;
      case "failed":
        return `The agent failed: ${clip(agent.error ?? "", AGENT_ERROR_MOST)}. The page stays as it last wrote it. · h history · ${open} · z clears`;
      case "stopped":
        return `The agent was stopped. · h history · ${open} · z clears`;
    }
  };

  const feedState = (): { status: TuiSpaceState["status"]; message: string } => {
    const error = view === "spaces" ? spacesError : spaceError;
    if (error !== null) return { status: "error", message: error };
    const feed = view === "spaces" ? spaces : space;
    if (!feed.ready) return { status: "loading", message: "Loading…" };
    return { status: "ready", message: "" };
  };

  const publish = () => {
    if (!open) {
      options.publish(CLOSED);
      return;
    }
    settleSelection();
    const rows = allRows();
    let { status, message } = feedState();
    if (status === "ready" && view === "history") {
      const page = pageById(pageId);
      if (history?.failed) {
        status = "error";
        message = "The history could not be loaded · h tries again";
      } else if (rows.length === 0) {
        message = history?.loading ? "Loading…" : "This page has no versions yet";
      } else if (page && !isLive(page)) {
        message = "This page is in the trash: restore it to bring back a version.";
      }
    } else if (status === "ready" && rows.length === 0) {
      message =
        view === "spaces"
          ? "No Spaces yet · n makes one"
          : view === "pages"
            ? "No pages yet · n makes one · i imports Markdown · t writes one from a thread"
            : view === "version"
              ? "This version has no blocks"
              : "An empty page · n adds a block";
    }
    if (status === "ready" && view === "page") {
      const agent = agentOfPage(pageId);
      if (agent) {
        message = agentText(agent);
        if (agent.status === "failed") status = "error";
      }
    }
    // Window the rows around the selection, under a message that may wrap.
    const messageRows = message === "" ? 0 : wrapWords(message, width()).length;
    const room = Math.max(1, options.height() - SPACE_CHROME_ROWS - messageRows);
    const first = rows.findIndex((row) => row.selected);
    const last = rows.findLastIndex((row) => row.selected);
    if (first >= 0) {
      if (first < top) top = first;
      if (last >= top + room) top = Math.max(0, Math.min(first, last - room + 1));
    }
    top = Math.max(0, Math.min(top, Math.max(0, rows.length - room)));
    options.publish({
      open: true,
      view,
      title: titleText(),
      hint: HINTS[view],
      status,
      message,
      rows: rows.slice(top, top + room),
    });
  };

  // --- streams ---

  const followSpaces = () => {
    if (unsubscribeSpaces) return;
    spaces = EMPTY_STREAM_ENTITIES;
    spacesError = null;
    let live = true;
    const stop = client.subscribeMcStream(
      SPACES_STREAM_ID,
      (frame) => {
        if (!live) return;
        spaces = foldStreamEntities(spaces, frame);
        onSpacesChanged();
      },
      (message) => {
        if (!live) return;
        spacesError = message;
        publish();
      },
    );
    unsubscribeSpaces = () => {
      live = false;
      stop();
    };
  };

  const followSpace = (id: string) => {
    unsubscribeSpace?.();
    space = EMPTY_STREAM_ENTITIES;
    spaceError = null;
    let live = true;
    const stop = client.subscribeMcStream(
      spaceStreamId(id as SpaceId),
      (frame: EntityStreamFrame) => {
        if (!live) return;
        space = foldStreamEntities(space, frame);
        onSpaceChanged();
      },
      (message) => {
        if (!live) return;
        spaceError = message;
        publish();
      },
    );
    unsubscribeSpace = () => {
      live = false;
      stop();
    };
  };

  const stopSpace = () => {
    unsubscribeSpace?.();
    unsubscribeSpace = null;
    space = EMPTY_STREAM_ENTITIES;
    spaceError = null;
  };

  // The open Space went away (deleted here or elsewhere): back to the Spaces.
  const onSpacesChanged = () => {
    if (spaceId !== null && spaces.ready && !currentSpace()) {
      options.status(`The Space was deleted.`, "info");
      leaveSpace();
    }
    publish();
  };

  // The open page went away (deleted for good): back to the tree.
  const onSpaceChanged = () => {
    const onPage = view === "page" || view === "history" || view === "version";
    if (onPage && space.ready && !pageById(pageId)) {
      closeHistory();
      pageId = null;
      generation += 1;
      view = "pages";
      top = 0;
    }
    // Any edit in the Space may be one to this page; the stream does not carry versions.
    if (history && historyTimer === null) {
      historyTimer = setTimeout(() => {
        historyTimer = null;
        askHistory();
      }, HISTORY_REFRESH_MS);
    }
    publish();
  };

  // --- navigation ---

  const openSpace = (id: string, then: TuiSpaceView = "pages") => {
    generation += 1;
    if (spaceId !== id) {
      spaceId = id;
      selected.pages = null;
      selectedIndex.pages = 0;
      followSpace(id);
    }
    view = then;
    top = 0;
    publish();
  };

  /** Opens a page; `key` is its row in the tree (a trashed page's is `trash:<id>`). */
  const openPage = (id: string, key = `page:${id}`) => {
    generation += 1;
    if (pageId !== id) {
      selected.page = null;
      selectedIndex.page = 0;
    }
    pageId = id;
    selected.pages = key;
    view = "page";
    top = 0;
    publish();
  };

  const leaveSpace = () => {
    generation += 1;
    closeHistory();
    stopSpace();
    spaceId = null;
    pageId = null;
    view = "spaces";
    top = 0;
  };

  const show = () => {
    if (!open) {
      open = true;
      options.setOpen(true);
    }
    followSpaces();
    // Listing makes the Personal Space on the first look; the stream shows it.
    void call(WS_METHODS.spaceList, {}).catch((error: unknown) =>
      options.status(refusalText(error), "error"),
    );
    publish();
  };

  const close = () => {
    if (!open) return;
    open = false;
    generation += 1;
    unsubscribeSpaces?.();
    unsubscribeSpaces = null;
    spaces = EMPTY_STREAM_ENTITIES;
    leaveSpace();
    options.setOpen(false);
    publish();
  };

  /** Esc and ←: up a level; closes from the Spaces. */
  const back = () => {
    if (view === "version") {
      readAsked += 1;
      reading = null;
      view = "history";
      top = 0;
      publish();
    } else if (view === "history") {
      closeHistory();
      view = "page";
      top = 0;
      publish();
    } else if (view === "page") {
      generation += 1;
      view = "pages";
      top = 0;
      publish();
    } else if (view === "pages") {
      const id = spaceId;
      leaveSpace();
      selected.spaces = id === null ? selected.spaces : `space:${id}`;
      publish();
    } else close();
  };

  const move = (delta: number) => {
    const keys = entryKeys(allRows());
    if (keys.length === 0) return;
    const index = keys.indexOf(selected[view] ?? "");
    const next = Math.max(0, Math.min(keys.length - 1, (index < 0 ? 0 : index) + delta));
    selected[view] = keys[next] ?? null;
    selectedIndex[view] = next;
    publish();
  };

  // --- what the keys do ---

  /** Runs an RPC; a refusal goes to the status line. Resolves to null when refused. */
  const send = async <T>(method: string, payload: unknown): Promise<T | null> => {
    try {
      return await call<T>(method, payload);
    } catch (error) {
      options.status(refusalText(error), "error");
      return null;
    }
  };

  // --- a page's history ---

  /** Forgets the history and anything still being asked of it; the caller picks the view. */
  const closeHistory = () => {
    historyAsked += 1;
    readAsked += 1;
    history = null;
    reading = null;
    askAgain = false;
    if (historyTimer !== null) clearTimeout(historyTimer);
    historyTimer = null;
  };

  /**
   * Asks for the versions again as far back as the user has looked, or with `more`
   * for the stretch before those. One request at a time, and a late reply is dropped.
   */
  const askHistory = (more = false) => {
    const current = history;
    if (!current) return;
    if (current.loading) {
      askAgain ||= !more;
      return;
    }
    const asked = historyAsked;
    const seen = current.versions.length;
    current.loading = true;
    current.failed = false;
    publish();
    void track(
      call<SpacePageHistoryResult>(WS_METHODS.spacePageHistory, {
        spaceId,
        pageId: current.pageId,
        ...(more
          ? { before: current.nextBefore, limit: HISTORY_STRETCH }
          : { limit: Math.max(HISTORY_STRETCH, Math.min(seen, HISTORY_MOST)) }),
      }).then(
        (result) => {
          if (asked !== historyAsked) return;
          current.versions = more ? [...current.versions, ...result.versions] : result.versions;
          current.nextBefore = result.nextBefore;
          settleHistory(current);
        },
        () => {
          if (asked !== historyAsked) return;
          current.failed = true;
          settleHistory(current);
        },
      ),
    );
  };

  const settleHistory = (current: PageHistory) => {
    current.loading = false;
    const again = askAgain;
    askAgain = false;
    if (again) askHistory();
    else publish();
  };

  /** h: the open or selected page's versions; in the history, asks for them again. */
  const showHistory = () => {
    if (view === "history") {
      askHistory();
      return;
    }
    if (view === "version") return;
    const id = view === "spaces" ? null : pageInView();
    if (id === null) {
      options.status("Open or select a page to see its history.", "info");
      return;
    }
    // Through the page, so that going back from the history lands on it.
    if (view === "pages") openPage(id, selected.pages ?? `page:${id}`);
    closeHistory();
    history = { pageId: id, versions: [], nextBefore: null, loading: false, failed: false };
    selected.history = null;
    selectedIndex.history = 0;
    view = "history";
    top = 0;
    askHistory();
  };

  const readVersion = (version: number) => {
    const current = history;
    if (!current) return;
    readAsked += 1;
    const asked = readAsked;
    void send<SpacePageVersionContent>(WS_METHODS.spacePageVersion, {
      spaceId,
      pageId: current.pageId,
      version,
    }).then((result) => {
      if (!result || asked !== readAsked) return;
      reading = result;
      selected.version = null;
      selectedIndex.version = 0;
      view = "version";
      top = 0;
      publish();
    });
  };

  /** The selected version, or the one being read, back onto the page as a new edit. */
  const restoreVersion = () => {
    const current = history;
    const entry = selectedEntry();
    const version =
      view === "version"
        ? reading?.version
        : entry?.kind === "version"
          ? Number(entry.id)
          : undefined;
    if (!current || version === undefined) return;
    if (current.versions[0]?.version === version) {
      options.status("This version is the page as it is.", "info");
      return;
    }
    const page = pageById(current.pageId);
    if (page && !isLive(page)) {
      options.status("This page is in the trash: restore it to bring back a version.", "info");
      return;
    }
    const asked = historyAsked;
    void send(WS_METHODS.spacePageRestoreVersion, {
      spaceId,
      pageId: current.pageId,
      version,
    }).then((result) => {
      if (!result) return;
      options.status("Version restored: restore the one before it to undo.", "info");
      if (asked !== historyAsked) return;
      readAsked += 1;
      reading = null;
      selected.history = null;
      selectedIndex.history = 0;
      view = "history";
      top = 0;
      askHistory();
    });
  };

  const activate = () => {
    const entry = selectedEntry();
    if (view === "version") return;
    if (view === "history") {
      if (entry?.kind === "version") readVersion(Number(entry.id));
      else if (entry?.kind === "more") askHistory(true);
      else askHistory();
      return;
    }
    if (!entry) return;
    if (entry.kind === "space") openSpace(entry.id);
    else if (entry.kind === "page") openPage(entry.id);
    else if (entry.kind === "trash") {
      // To read it: the MC refuses edits to a page in the trash, and r restores it from here.
      openPage(entry.id, `trash:${entry.id}`);
      options.status("This page is in the trash: r restores it.", "info");
    } else if (entry.kind === "block") {
      const block = blocksOf(pageId ?? "").find((candidate) => candidate.id === entry.id);
      if (block?.kind === "subpage_link" && block.linkedPageId) {
        const linked = pageById(block.linkedPageId);
        if (linked && isLive(linked)) openPage(linked.id);
        else options.status("The linked page is in the trash or gone.", "info");
      } else edit();
    }
  };

  const newEntry = () => {
    if (view === "spaces") {
      options.ask({
        label: "new Space",
        placeholder: "name",
        returnMode: "compose",
        onSubmit: (name) => {
          void send(WS_METHODS.spaceCreate, { name });
        },
      });
    } else if (view === "pages") newPage(null);
    else addBlock();
  };

  const newPage = (parentPageId: string | null) => {
    const id = spaceId;
    if (id === null) return;
    const parent = parentPageId === null ? undefined : pageById(parentPageId);
    const asked = generation;
    options.ask({
      label: parent ? `new page in ${parent.title}` : "new page",
      placeholder: "title",
      onSubmit: (title) => {
        void send<{ page: SpacePage }>(WS_METHODS.spacePageCreate, {
          spaceId: id,
          title,
          ...(parentPageId === null ? {} : { parentPageId }),
        }).then((result) => {
          if (result && asked === generation && spaceId === id) {
            selected.pages = `page:${result.page.id}`;
            publish();
          }
        });
      },
    });
  };

  const newSubpage = () => {
    const entry = selectedEntry();
    if (view !== "pages" || entry?.kind !== "page") {
      options.status("Select a page in the Space to make a page inside it.", "info");
      return;
    }
    newPage(entry.id);
  };

  /** Where a new block goes: after the selected block, or after the block a comment is on. */
  const anchorBlock = (): string | null => {
    const entry = selectedEntry();
    if (!entry) return null;
    if (entry.kind === "block") return entry.id;
    if (entry.kind === "comment") {
      const comment = commentsOf(pageId ?? "").find((candidate) => candidate.id === entry.id);
      const onPage = blocksOf(pageId ?? "").some((block) => block.id === comment?.blockId);
      return onPage ? (comment?.blockId ?? null) : null;
    }
    return null;
  };

  const insertBlock = (input: Record<string, unknown>) => {
    const id = spaceId;
    const page = pageId;
    if (id === null || page === null) return;
    const after = anchorBlock();
    const asked = generation;
    void send<{ block: SpaceBlock }>(WS_METHODS.spaceBlockInsert, {
      spaceId: id,
      pageId: page,
      ...input,
      ...(after === null ? {} : { afterBlockId: after }),
    }).then((result) => {
      if (result && asked === generation && pageId === page) {
        selected.page = `block:${result.block.id}`;
        publish();
      }
    });
  };

  const addBlock = () => {
    options.menu({
      title: "Add a block",
      options: BLOCK_KINDS.map((entry) => ({ label: entry.label, value: entry.kind })),
      onChoose: (value) => {
        const kind = value as SpaceBlockKind;
        if (kind === "subpage_link") {
          link();
          return;
        }
        const name = BLOCK_KINDS.find((entry) => entry.kind === kind)!.label.toLowerCase();
        options.ask({
          label: name,
          placeholder: "text",
          onSubmit: (text) => insertBlock({ kind, text }),
        });
      },
    });
  };

  const link = () => {
    if (view !== "page" || pageId === null) return;
    const children = pages().filter((page) => page.parentPageId === pageId && isLive(page));
    if (children.length === 0) {
      options.status(
        "This page has no subpages to link; make one with a in the page list.",
        "info",
      );
      return;
    }
    options.menu({
      title: "Link a subpage",
      options: children.map((page) => ({ label: page.title, value: page.id })),
      onChoose: (linkedPageId) => insertBlock({ kind: "subpage_link", linkedPageId }),
    });
  };

  const edit = () => {
    const entry = selectedEntry();
    if (!entry) return;
    if (entry.kind === "space") {
      const current = spaceList().find((candidate) => candidate.id === entry.id);
      options.ask({
        label: "rename Space",
        value: current?.name ?? "",
        onSubmit: (name) => {
          void send(WS_METHODS.spaceRename, { spaceId: entry.id, name });
        },
      });
    } else if (entry.kind === "page" || entry.kind === "trash") {
      const id = spaceId;
      options.ask({
        label: "rename page",
        value: pageById(entry.id)?.title ?? "",
        onSubmit: (title) => {
          void send(WS_METHODS.spacePageRename, { spaceId: id, pageId: entry.id, title });
        },
      });
    } else if (entry.kind === "block") {
      const id = spaceId;
      const block = blocksOf(pageId ?? "").find((candidate) => candidate.id === entry.id);
      if (block?.kind === "subpage_link") {
        options.status("A link shows its page's title: rename the page instead.", "info");
        return;
      }
      options.ask({
        label: "edit block",
        value: block?.text ?? "",
        onSubmit: (text) => {
          void send(WS_METHODS.spaceBlockUpdate, { spaceId: id, blockId: entry.id, text });
        },
      });
    }
  };

  const remove = () => {
    const entry = selectedEntry();
    const id = spaceId;
    if (!entry) return;
    if (entry.kind === "space") {
      void send(WS_METHODS.spaceDelete, { spaceId: entry.id });
    } else if (entry.kind === "page") {
      void send(WS_METHODS.spacePageTrash, { spaceId: id, pageId: entry.id }).then((result) => {
        if (result) options.status("Moved to the trash: r restores it.", "info");
      });
    } else if (entry.kind === "trash") {
      deleteForGood();
    } else if (entry.kind === "block") {
      void send(WS_METHODS.spaceBlockDelete, { spaceId: id, blockId: entry.id });
    } else if (entry.kind === "comment") {
      options.status("Comments are resolved, not deleted: x resolves or reopens.", "info");
    }
  };

  /**
   * Deletes the selected page and its subpages for good, once confirmed. Only a page
   * in the trash can go; the MC says so for one that is not.
   */
  const deleteForGood = () => {
    const entry = selectedEntry();
    const id = spaceId;
    if (view !== "pages" || (entry?.kind !== "page" && entry?.kind !== "trash")) {
      options.status("Select a page in the trash to delete it for good.", "info");
      return;
    }
    const title = pageById(entry.id)?.title ?? "this page";
    options.menu({
      title: `Delete “${title}” for good, with its subpages?`,
      options: [
        { label: entry.kind === "trash" ? "Keep it in the trash" : "Keep it", value: "keep" },
        { label: "Delete for good", value: "delete" },
      ],
      onChoose: (value) => {
        if (value === "delete") {
          void send(WS_METHODS.spacePageDelete, { spaceId: id, pageId: entry.id });
        }
      },
    });
  };

  const restore = () => {
    if (view === "history" || view === "version") {
      restoreVersion();
      return;
    }
    const entry = selectedEntry();
    if (entry?.kind === "trash") {
      void send(WS_METHODS.spacePageRestore, { spaceId, pageId: entry.id });
    } else if (view === "page" && pageId !== null && !isLive(pageById(pageId)!)) {
      void send(WS_METHODS.spacePageRestore, { spaceId, pageId });
    } else options.status("Only a page in the trash can be restored.", "info");
  };

  /** Ticks or unticks a checklist item; resolves or reopens a comment. */
  const toggle = () => {
    const entry = selectedEntry();
    if (entry?.kind === "block") {
      const block = blocksOf(pageId ?? "").find((candidate) => candidate.id === entry.id);
      if (block?.kind !== "checklist") {
        options.status("Only a checklist item can be ticked.", "info");
        return;
      }
      void send(WS_METHODS.spaceBlockSetChecked, {
        spaceId,
        blockId: entry.id,
        checked: !block.checked,
      });
    } else if (entry?.kind === "comment") {
      const comment = commentsOf(pageId ?? "").find((candidate) => candidate.id === entry.id);
      void send(
        comment?.resolvedAt ? WS_METHODS.spaceCommentReopen : WS_METHODS.spaceCommentResolve,
        { spaceId, commentId: entry.id },
      );
    }
  };

  const isActive = (agent: SpacePageAgent) =>
    agent.status === "running" || agent.status === "stopping";

  /** The MC takes the word @agent off what is asked, so the field takes it with or without. */
  const askAgent = () => {
    const page = pageId;
    if (view !== "page" || page === null) return;
    const current = agentOfPage(page);
    if (current && isActive(current)) {
      options.status("An agent is already working on this page: s stops it.", "info");
      return;
    }
    options.ask({
      label: "ask an agent",
      placeholder: "what to do to this page",
      onSubmit: (request) => {
        void send(WS_METHODS.spacePageAskAgent, { spaceId, pageId: page, request });
      },
    });
  };

  /** Runs `fn` on the open page's agent; a page without one says so. */
  const withAgent = (fn: (agent: SpacePageAgent) => void) => () => {
    if (view !== "page") return;
    const agent = agentOfPage(pageId);
    if (agent) fn(agent);
    else options.status("No agent was asked on this page: g asks one.", "info");
  };

  const stopAgent = withAgent((agent) => {
    void send(WS_METHODS.spacePageStopAgent, { spaceId, pageId: agent.pageId });
  });

  const dismissAgent = withAgent((agent) => {
    void send(WS_METHODS.spacePageDismissAgent, { spaceId, pageId: agent.pageId });
  });

  const openAgentThread = withAgent((agent) => {
    if (options.threads().some((thread) => thread.id === agent.threadId)) {
      options.openThread(agent.threadId);
    } else {
      options.status("The agent's thread is not available.", "info");
    }
  });

  const comment = () => {
    const page = pageId;
    if (view !== "page" || page === null) return;
    const blockId = anchorBlock();
    options.ask({
      label: blockId === null ? "comment on the page" : "comment",
      placeholder: "what to say",
      onSubmit: (body) => {
        void send(WS_METHODS.spaceCommentAdd, { spaceId, pageId: page, blockId, body });
      },
    });
  };

  const moveEntry = () => {
    const entry = selectedEntry();
    if (!entry) return;
    if (entry.kind === "page") {
      const page = pageById(entry.id);
      if (!page) return;
      options.menu({
        title: `Move “${page.title}” to`,
        searchable: true,
        options: [
          { label: "The top of the Space", value: "" },
          // Every page: the MC refuses a move into the page itself or one inside it.
          ...liveTree().map((row) => ({ label: row.page.title, value: row.page.id })),
        ],
        onChoose: (parent) => {
          void send(WS_METHODS.spacePageMove, {
            spaceId,
            pageId: page.id,
            parentPageId: parent === "" ? null : parent,
          });
        },
      });
    } else if (entry.kind === "block") {
      const blocks = blocksOf(pageId ?? "");
      const block = blocks.find((candidate) => candidate.id === entry.id);
      if (!block) return;
      const others = blocks.filter((candidate) => candidate.id !== block.id);
      const name = (target: SpaceBlock) =>
        target.kind === "subpage_link"
          ? (pageById(target.linkedPageId)?.title ?? "a link")
          : target.text;
      options.menu({
        title: `Move “${name(block)}”`,
        options: [
          ...others.map((target) => ({ label: `Before “${name(target)}”`, value: target.id })),
          { label: "To the end", value: "" },
        ],
        onChoose: (before) => {
          // Before a block is after the one ahead of it, first when there is none.
          const index = others.findIndex((target) => target.id === before);
          const afterBlockId =
            before === "" ? (others.at(-1)?.id ?? null) : index > 0 ? others[index - 1]!.id : null;
          void send(WS_METHODS.spaceBlockMove, { spaceId, blockId: block.id, afterBlockId });
        },
      });
    }
  };

  /** The page to export: the open one, or the one selected in the tree. */
  const pageInView = (): string | null => {
    if (view === "page") return pageId;
    const entry = selectedEntry();
    return entry?.kind === "page" || entry?.kind === "trash" ? entry.id : null;
  };

  const exportMarkdown = () => {
    const page = pageInView();
    if (page === null) {
      options.status("Open or select a page to copy it as Markdown.", "info");
      return;
    }
    const title = pageById(page)?.title ?? "the page";
    void send<{ markdown: string }>(WS_METHODS.spacePageExportMarkdown, {
      spaceId,
      pageId: page,
    }).then((result) => {
      if (!result) return;
      if (options.copy?.(result.markdown) === true) {
        options.status(`Copied “${title}” as Markdown.`, "info");
      } else options.status("This terminal cannot reach the clipboard.", "warning");
    });
  };

  const importMarkdown = () => {
    const id = spaceId;
    if (view !== "pages" || id === null) return;
    const read = options.readLocalText;
    if (!read) {
      options.status("Markdown cannot be read on this device.", "error");
      return;
    }
    const asked = generation;
    options.ask({
      label: "import Markdown file",
      placeholder: "path on this machine",
      onSubmit: (path) => {
        void track(
          read(path).then(
            async (markdown) => {
              const result = await send<{ page: SpacePage }>(WS_METHODS.spacePageImportMarkdown, {
                spaceId: id,
                markdown,
              });
              if (result && asked === generation && spaceId === id) openPage(result.page.id);
            },
            (error: unknown) =>
              options.status(
                `Could not read ${path}: ${error instanceof Error ? error.message : String(error)}`,
                "error",
              ),
          ),
        );
      },
    });
  };

  const fromThread = () => {
    const id = spaceId;
    if (view !== "pages" || id === null) {
      options.status("Open a Space to write a page from a thread.", "info");
      return;
    }
    const current = options.currentThreadId?.() ?? null;
    const threads = options.threads();
    if (threads.length === 0) {
      options.status("There are no threads to write a page from.", "info");
      return;
    }
    const asked = generation;
    options.menu({
      title: "Write a page from the thread",
      searchable: true,
      index: Math.max(
        0,
        threads.findIndex((thread) => thread.id === current),
      ),
      options: threads.map((thread) => ({ label: thread.title, value: thread.id })),
      onChoose: (threadId) => {
        options.status(`Writing a page from “${threadTitle(threadId)}”…`, "info");
        void send<{ page: SpacePage }>(WS_METHODS.spacePageCreateFromThread, {
          spaceId: id,
          threadId,
        }).then((result) => {
          if (!result) return;
          options.status(`Wrote “${result.page.title}”.`, "info");
          if (asked === generation && spaceId === id) openPage(result.page.id);
        });
      },
    });
  };

  const selectKey = (key: unknown) => {
    if (typeof key !== "string") return;
    const keys = entryKeys(allRows());
    const index = keys.indexOf(key);
    if (index < 0) return;
    selected[view] = key;
    selectedIndex[view] = index;
    publish();
  };

  const page = (delta: number) =>
    move(delta * Math.max(1, options.height() - SPACE_CHROME_ROWS - 1));

  /** The actions that need the pane open on a level. */
  const inView = (fn: () => void) => () => {
    if (open) fn();
    return open;
  };

  /** Editing keys: a page's history is only read, and restored from. */
  const onPages = (fn: () => void) =>
    inView(() => {
      if (view !== "history" && view !== "version") fn();
    });

  const actions: Record<string, (payload: unknown) => boolean> = {
    "space.open": () => {
      show();
      return true;
    },
    "space.toggle": () => {
      if (open) close();
      else show();
      return true;
    },
    "space.close": () => {
      close();
      return true;
    },
    "space.previous": inView(() => move(-1)),
    "space.next": inView(() => move(1)),
    "space.pageUp": inView(() => page(-1)),
    "space.pageDown": inView(() => page(1)),
    "space.activate": inView(activate),
    "space.back": inView(back),
    "space.new": onPages(newEntry),
    "space.newInside": onPages(newSubpage),
    "space.edit": onPages(edit),
    "space.delete": onPages(remove),
    "space.deleteForGood": onPages(deleteForGood),
    "space.restore": inView(restore),
    "space.history": inView(showHistory),
    "space.tick": onPages(toggle),
    "space.comment": onPages(comment),
    "space.askAgent": onPages(askAgent),
    "space.stopAgent": onPages(stopAgent),
    "space.dismissAgent": onPages(dismissAgent),
    "space.openAgentThread": onPages(openAgentThread),
    "space.move": onPages(moveEntry),
    "space.link": onPages(link),
    "space.export": onPages(exportMarkdown),
    "space.import": onPages(importMarkdown),
    "space.fromThread": onPages(fromThread),
    "space.select": (payload) => {
      if (!open) return false;
      selectKey(
        typeof payload === "object" && payload !== null
          ? (payload as { key?: unknown }).key
          : undefined,
      );
      return true;
    },
  };

  options.publish(CLOSED);

  return {
    dispatch: (action, payload) => actions[action]?.(payload) ?? false,
    close,
    isOpen: () => open,
    mode: () => "space",
    sync: () => {
      if (open) publish();
    },
    commands: () => {
      const entries: Array<{ title: string; action: string }> = [
        { title: open ? "Close Spaces" : "Spaces", action: open ? "space.close" : "space.open" },
      ];
      if (!open) return entries;
      if (view === "spaces") {
        entries.push(
          { title: "New Space", action: "space.new" },
          { title: "Rename Space", action: "space.edit" },
          { title: "Delete Space", action: "space.delete" },
        );
      } else if (view === "pages") {
        entries.push(
          { title: "New page", action: "space.new" },
          { title: "New page inside the selected page", action: "space.newInside" },
          { title: "Rename page", action: "space.edit" },
          { title: "Move page", action: "space.move" },
          { title: "Move page to the trash", action: "space.delete" },
          { title: "Delete page for good", action: "space.deleteForGood" },
          { title: "Restore page from the trash", action: "space.restore" },
          { title: "Import a Markdown file as a page", action: "space.import" },
          { title: "Write a page from a thread", action: "space.fromThread" },
          { title: "Copy page as Markdown", action: "space.export" },
          { title: "Page history", action: "space.history" },
        );
      } else if (view === "history") {
        entries.push(
          { title: "Read version", action: "space.activate" },
          { title: "Restore version", action: "space.restore" },
        );
      } else if (view === "version") {
        entries.push({ title: "Restore this version", action: "space.restore" });
      } else {
        entries.push(
          { title: "Add a block", action: "space.new" },
          { title: "Edit block", action: "space.edit" },
          { title: "Move block", action: "space.move" },
          { title: "Delete block", action: "space.delete" },
          { title: "Tick / untick, resolve / reopen", action: "space.tick" },
          { title: "Comment on the block", action: "space.comment" },
          { title: "Link a subpage", action: "space.link" },
          { title: "Copy page as Markdown", action: "space.export" },
          { title: "Restore page from the trash", action: "space.restore" },
          { title: "Page history", action: "space.history" },
        );
        const agent = agentOfPage(pageId);
        if (!agent || !isActive(agent)) {
          entries.push({ title: "Ask an agent about this page", action: "space.askAgent" });
        }
        if (agent) {
          entries.push({ title: "Open the agent's thread", action: "space.openAgentThread" });
          entries.push(
            isActive(agent)
              ? { title: "Stop the agent", action: "space.stopAgent" }
              : { title: "Clear what the page says about its agent", action: "space.dismissAgent" },
          );
        }
      }
      return entries;
    },
    settled: async () => {
      while (pending.size > 0) await Promise.allSettled(pending);
    },
    dispose: () => {
      unsubscribeSpaces?.();
      unsubscribeSpaces = null;
      closeHistory();
      stopSpace();
    },
  };
}
