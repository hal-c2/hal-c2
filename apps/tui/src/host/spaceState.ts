// Spaces and their pages and decks (^X p, palette → Spaces), host side. The pane takes
// the conversation's place like the file browser, at one of six levels: the Spaces,
// one Space's page tree with its decks and trash, one page's blocks with their comments,
// one deck's slides, one slide being presented, and the Space's images with theirs,
// listed by name and prompt: a terminal draws none.
// Everything shown comes from the MC's streams (`spaces`, `space:<id>`), so an edit
// from another client or an agent shows as it lands; the keys only send `space.*`
// RPCs. A page's history (h) is the exception: it is not on a stream, so it is asked
// for while it is open, again when the Space's stream moves. The SpaceView brick
// paints `space` and dispatches `space.*`. A chart block draws as text (`spaceChart.ts`)
// and is asked for in words. A Mermaid diagram (a `code` block in "mermaid", or, as the
// fallback, a `raw` block that is one Mermaid fence the page keeps as written) shows as
// the MC drew it in characters (`mermaidDiagrams.ts`). Any other `raw`, `table` or
// `code` block shows as its source, line for line. An image, the Space's or one by its
// address, is named in words and never fetched. A heading carries its level's `#`
// marks, a checklist item its box and a callout a bar; a bullet, a numbered item, a
// divider, a footnote, a `details` and a `details_end` show their text. An entry taller
// than the pane, as a chart can be, scrolls through itself before the selection moves on.
import * as NodePath from "node:path";

import {
  PROVIDER_SEND_TURN_MAX_IMAGE_BYTES,
  SPACES_STREAM_ID,
  type Space,
  type SpaceAuthor,
  type SpaceBlock,
  type SpaceBlockKind,
  type SpaceComment,
  type SpaceDeck,
  type SpaceFilesListResult,
  type SpaceFilesScanResult,
  type SpaceId,
  type SpaceImage,
  type SpaceImageProvidersResult,
  type SpacePage,
  type SpacePageAgent,
  type SpacePageAgentTarget,
  type SpacePageHistoryResult,
  type SpacePageId,
  type SpacePageOpenFileResult,
  type SpacePageSchedule,
  type SpacePageVersion,
  type SpacePageVersionContent,
  type SpaceSite,
  type SpaceSlide,
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
import type { ComposerPage, PagePrompt, PickRequest } from "./composerState.ts";
import { scheduleLabel } from "./sections/scheduledTasks.ts";
import { loopbackHost } from "../thisMachine.ts";
import { wrapWords } from "./settingsSections.ts";
import { chartData, chartLines } from "./spaceChart.ts";
import { createMermaidDiagrams, type MermaidDiagrams } from "./mermaidDiagrams.ts";
import { chunk, mermaidFenceSource, mermaidLines, styled, type StyledText } from "./styledText.ts";

/** Rows the pane's border and header take. */
export const SPACE_CHROME_ROWS = 3;

export type TuiSpaceView =
  | "spaces"
  | "pages"
  | "page"
  | "deck"
  | "present"
  | "images"
  | "history"
  | "version";

export interface TuiSpaceRow {
  /**
   * `space:<id>`, `page:<id>`, `trash:<id>`, `deck:<id>`, `decktrash:<id>`, `block:<id>`,
   * `comment:<id>`, `slide:<id>`, `image:<id>`, `imageTrash:<id>`, `version:<n>`,
   * `more:more`; a wrapped block or a slide's body repeats its key.
   */
  readonly key: string;
  readonly kind:
    | "space"
    | "page"
    | "deck"
    | "trashed"
    | "block"
    | "comment"
    | "slide"
    | "image"
    | "trashedImage"
    | "version"
    | "more"
    | "label";
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
   * The header: `spaces`, `space · Research`, `page · Roadmap`, `deck · Pitch`,
   * `present · Pitch · 2 / 3`, `history · Roadmap`, `version · Roadmap · <when>`, in
   * accent; then the keys, dimmed.
   */
  readonly title: string;
  readonly hint: string;
  readonly status: "loading" | "ready" | "error";
  /** Who else is on the open page, "" when nobody is. */
  readonly viewers: string;
  /** The body line when there are no rows (loading, empty, the stream's refusal). */
  readonly message: string;
  /** The rows that fit, windowed around the selection. */
  readonly rows: ReadonlyArray<TuiSpaceRow>;
}

export interface SpaceControllerOptions {
  readonly client: Pick<
    TuiClient,
    "mcCall" | "subscribeMcStream" | "subscribeSpacePresence" | "uploadToMc"
  >;
  readonly height: () => number;
  readonly width: () => number;
  readonly palette?: Palette;
  /** The Mermaid drawings the MC sent, shared with the timeline and file viewer. */
  readonly diagrams?: MermaidDiagrams;
  readonly setOpen: (open: boolean) => void;
  readonly publish: (state: TuiSpaceState) => void;
  readonly status: (text: string, kind?: StatusKind) => void;
  /** A one-line question in the prompt's place. */
  readonly ask: (spec: AskSpec) => void;
  /** A picker over the pane. */
  readonly menu: (spec: PickRequest) => void;
  /** Put text on the clipboard; false when the terminal cannot. */
  readonly copy?: (text: string) => boolean;
  /** The address this client reached the MC at; a site link is made on it. */
  readonly origin?: string;
  /** Read a Markdown file on this machine to import it. */
  readonly readLocalText?: (path: string) => Promise<string>;
  /** Read an image file on this machine to add it; rejects saying why when over `maxBytes`. */
  readonly readLocalBytes?: (path: string, maxBytes: number) => Promise<Uint8Array>;
  /** The threads a page can be made from, and whose names show on agents' edits. */
  readonly threads: () => ReadonlyArray<{ readonly id: string; readonly title: string }>;
  /** The selected thread, offered first when making a page from a thread. */
  readonly currentThreadId?: () => string | null;
  /** Leave the pane for a thread: the one a page's agent runs in. */
  readonly openThread: (threadId: string) => void;
  /** This MC's projects, whose files can be opened as pages. */
  readonly projects?: () => ReadonlyArray<{ readonly id: string; readonly title: string }>;
  /** Leave the pane for a project's file in the file viewer: a page's file. */
  readonly showFile?: (projectId: string, path: string) => void;
  /** The entries `commands` offers changed without the pane moving. */
  readonly commandsChanged?: () => void;
  /** What `prompt` aims at changed, or whether the prompt has the page's keys. */
  readonly promptChanged?: () => void;
  /** Starts an ask in the page's prompt, keeping what is written there. */
  readonly askInPrompt?: () => void;
}

/** A palette entry; one offered several times is told apart by its payload. */
export interface SpaceCommand {
  readonly title: string;
  readonly action: string;
  readonly payload?: unknown;
}

export interface SpaceController {
  /** Handles a `space.*` action; false when it is not one. */
  readonly dispatch: (action: string, payload: unknown) => boolean;
  readonly close: () => void;
  readonly isOpen: () => boolean;
  /** "pagePrompt" while the open page's prompt has the keys (^P). */
  readonly mode: () => "space" | "pagePrompt";
  /** The open page, for the timeline's prompt to write on; null off a page. */
  readonly prompt: () => ComposerPage | null;
  /** Republish after a resize or a theme change. */
  readonly sync: () => void;
  /** The connection is down: who is on the page is unknown until the MC's next frame. */
  readonly connectionLost: () => void;
  readonly commands: () => ReadonlyArray<SpaceCommand>;
  /**
   * Whether the MC counts a project's file as Space content, as it last said. The
   * first question about a project asks the MC, and `commandsChanged` follows its answer.
   */
  readonly isSpaceFile: (projectId: string, path: string) => boolean;
  /** Asks the MC again which of a project's files are Space content. */
  readonly refreshSpaceFiles: (projectId: string) => void;
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
  viewers: "",
  message: "",
  rows: [],
};

const HINTS: Record<TuiSpaceView, string> = {
  spaces: "  ⏎ open · n new · e rename · d delete · esc close",
  pages:
    "  ⏎ open · n new · s new deck · S deck from page · a subpage · e rename · m move · d trash · r restore · D delete · p present a deck, publish a page · i import · f from a project's files · t from thread · h history · v images · esc back",
  page: "  ^P write · ⏎ edit · n add · g chart · c comment · x tick/resolve · m move · d delete · l link · u update · y copy · S deck · p publish · h history · v images · A ask an agent · f its file · F unlink · esc back",
  deck: "  ⏎ edit · n add · m move · d delete · p present · r restore · v images · esc back",
  present: "  → next · ← back · pgup/pgdn scroll · esc leave",
  images: "  n generate · i add a file · d trash · r restore · D delete · esc back",
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

const UNTITLED = "(untitled)";

/**
 * A slide's body, or a raw block's Markdown, for the one-line field: a line break is
 * `\n`, a backslash `\\`, all else as written.
 */
const bodyToField = (body: string) => body.replaceAll("\\", "\\\\").replaceAll("\n", "\\n");

/** What `bodyToField` wrote, or typed: a backslash before anything else stays a backslash. */
const bodyFromField = (text: string) =>
  text.replace(/\\([\\n])/g, (_, escaped) => (escaped === "n" ? "\n" : "\\"));

export const SITE_BEHIND_HINT = "Edited since it was published · p publishes again";
export const SITE_LOCAL_ONLY_HINT =
  "Only this machine can open this link · P publishes over Tailscale";

/** What sets a raw block's source apart from the page's own blocks. */
const RAW_GUTTER = "│ ";

/** A source line with its tabs as spaces to the next stop of four, as Markdown reads them. */
const expandTabs = (line: string) => {
  const [first = "", ...rest] = line.split("\t");
  let out = first;
  for (const part of rest) out += `${" ".repeat(4 - (Bun.stringWidth(out) % 4))}${part}`;
  return out;
};

const BLOCK_KINDS: ReadonlyArray<{ readonly kind: SpaceBlockKind; readonly label: string }> = [
  { kind: "paragraph", label: "Paragraph" },
  { kind: "heading", label: "Heading" },
  { kind: "checklist", label: "Checklist item" },
  { kind: "callout", label: "Callout" },
  { kind: "subpage_link", label: "Link to a subpage" },
  { kind: "chart", label: "Chart" },
  { kind: "image", label: "Image" },
];

/** What "/" in a page's prompt offers: a chart is asked for in words, so it is "Visualize". */
const PROMPT_KINDS = BLOCK_KINDS.map((entry) =>
  entry.kind === "chart"
    ? { label: "Visualize", value: entry.kind }
    : { label: entry.label, value: entry.kind },
);

/** What a page's prompt writes from plain words, after "/" chose it. */
const PROMPT_WRITES: Partial<Record<SpaceBlockKind, string>> = {
  paragraph: "writes a paragraph",
  heading: "writes a heading",
  checklist: "writes a checklist item",
  callout: "writes a callout",
};

/** An ask in a page's prompt starts with the word @agent; the MC is sent what follows. */
const ASK_PREFIX = /^@agent(?:\s+|$)/i;
const VISUALIZE_PREFIX = /^\/visualize(?:\s+|$)/i;

const HOUR_MS = 3_600_000;

/** How often a page's update runs. */
function cadenceText(cadence: SpacePageSchedule["cadence"]): string {
  if (cadence.type === "interval" && cadence.everyMs % HOUR_MS === 0) {
    const hours = cadence.everyMs / HOUR_MS;
    return hours === 1 ? "Every hour" : `Every ${hours} hours`;
  }
  return scheduleLabel(cadence);
}

/** The clock's time, not "5m ago", so a row nobody redraws does not go stale. */
const clockText = (iso: string) =>
  new Date(iso).toLocaleString(undefined, { dateStyle: "short", timeStyle: "short" });

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
  if (tag === "SpaceImageGenerationError") {
    if (reason === "unavailable") {
      return `Image generation is unavailable, so no image was made: ${message}`;
    }
    if (reason === "failed") return `Image generation failed, so no image was made: ${message}`;
  }
  return message;
}

/**
 * What kind of image these bytes start like, null when none the MC keeps. The MC
 * decides for good; this saves sending a file only for it to be refused.
 */
export function imageTypeOf(bytes: Uint8Array): string | null {
  const ascii = (from: number, to: number) => String.fromCharCode(...bytes.subarray(from, to));
  if (bytes[0] === 0x89 && ascii(1, 4) === "PNG") return "image/png";
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "image/jpeg";
  if (ascii(0, 4) === "GIF8") return "image/gif";
  if (ascii(0, 4) === "RIFF" && ascii(8, 12) === "WEBP") return "image/webp";
  return null;
}

const byOrder = (a: { readonly order: string }, b: { readonly order: string }) =>
  a.order < b.order ? -1 : a.order > b.order ? 1 : 0;

export function createSpaceController(options: SpaceControllerOptions): SpaceController {
  const { client } = options;
  const palette = options.palette ?? THEME;
  const diagrams = options.diagrams ?? createMermaidDiagrams(client);
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
  let viewersPage: string | null = null;
  let viewers = "";
  let unsubscribeViewers: (() => void) | null = null;
  // The rows the last publish had room for, which a move or a page up or down steps within.
  let rowsOnShow = 1;
  let deckId: string | null = null;
  // The slide on show, by id so a move elsewhere keeps it; its index for when it goes.
  let shownSlideId: string | null = null;
  let shownIndex = 0;
  // The level the images were opened from, where Esc goes back to.
  let imagesFrom: "pages" | "page" | "deck" = "pages";
  // The selected entry per level, by row key, so the selection stays put as rows come and go.
  const selected: Record<TuiSpaceView, string | null> = {
    spaces: null,
    pages: null,
    page: null,
    deck: null,
    present: null,
    images: null,
    history: null,
    version: null,
  };
  // The last selected index per level: where the selection lands when its row goes away.
  const selectedIndex: Record<TuiSpaceView, number> = {
    spaces: 0,
    pages: 0,
    page: 0,
    deck: 0,
    present: 0,
    images: 0,
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
  // The open page's prompt: whether it has the keys, what its plain words write (as "/"
  // chose), where an ask naming no project runs (as the MC last said), and what it
  // last published, so the prompt is told only when that changes.
  let prompting = false;
  let nextKind: SpaceBlockKind = "paragraph";
  let agentTarget: string | null = null;
  let promptSignature = "";
  let pagePrompt: ComposerPage | null = null;

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
  // The open Space: one of the user's, or a project's own (its files' pages), which the
  // index holds as a `projectSpace` and the list of Spaces leaves out.
  const currentSpace = (): Space | undefined =>
    [...spaceList(), ...(entitiesOf(spaces, "projectSpace") as unknown as Space[])].find(
      (s) => s.id === spaceId,
    );
  const pages = (): SpacePage[] => entitiesOf(space, "page") as unknown as SpacePage[];
  const pageById = (id: string | null) => pages().find((page) => page.id === id);
  const blocksOf = (id: string): SpaceBlock[] =>
    (entitiesOf(space, "block") as unknown as SpaceBlock[])
      .filter((block) => block.pageId === id)
      .toSorted(byOrder);
  /** The site a page is published as, if it is. */
  const siteOf = (id: string | null): SpaceSite | undefined =>
    (entitiesOf(space, "site") as unknown as SpaceSite[]).find((site) => site.pageId === id);
  const commentsOf = (id: string): SpaceComment[] =>
    (entitiesOf(space, "comment") as unknown as SpaceComment[]).filter(
      (comment) => comment.pageId === id,
    );

  const decks = (): SpaceDeck[] => entitiesOf(space, "deck") as unknown as SpaceDeck[];
  const deckById = (id: string | null) => decks().find((deck) => deck.id === id);
  const slidesOf = (id: string | null): SpaceSlide[] =>
    (entitiesOf(space, "slide") as unknown as SpaceSlide[])
      .filter((slide) => slide.deckId === id)
      .toSorted(byOrder);

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

  const images = (): SpaceImage[] => entitiesOf(space, "image") as unknown as SpaceImage[];
  const imageById = (id: string | undefined) => images().find((image) => image.id === id);
  const liveImages = () => images().filter((image) => image.trashedAt === null);
  const trashedImages = () => images().filter((image) => image.trashedAt !== null);

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

  /** Its title, its plot with the numbers, and where the numbers came from. */
  const chartRows = (
    block: SpaceBlock,
    chart: NonNullable<ReturnType<typeof chartData>>,
  ): TuiSpaceRow[] => {
    const key = `block:${block.id}`;
    const active = selected.page === key;
    const bg = active ? { bg: palette.selectedBg } : {};
    const room = width() - 2;
    const row = (lead: string, line: StyledText, text: string, first = false): TuiSpaceRow => ({
      key,
      kind: "block",
      text: `${lead}${text}`,
      line,
      selected: active,
      blockKind: block.kind,
      first,
    });
    const agent = agentOf(block);
    const sources = wrapWords(chart.source === "" ? " " : chart.source, room);
    return [
      ...wrapWords(chart.title === "" ? " " : chart.title, room).map((text, index) => {
        const lead = index === 0 ? marker(active) : "  ";
        return row(
          lead,
          styled(
            chunk(lead, { fg: palette.dim, ...bg }),
            chunk(text, { fg: palette.text, bold: true, ...bg }),
          ),
          text,
          index === 0,
        );
      }),
      ...chartLines(chart, room).map(({ words, bar, number, header }) =>
        row(
          "  ",
          styled(
            chunk("  ", bg),
            chunk(words, { fg: header ? palette.dim : palette.text, ...bg }),
            bar !== "" && chunk(bar, { fg: palette.accent, ...bg }),
            number !== "" && chunk(number, { fg: palette.text, ...bg }),
          ),
          `${words}${bar}${number}`,
        ),
      ),
      ...sources.map((text, index) => {
        const by = index === sources.length - 1 && agent ? `  · ${agent}` : "";
        return row(
          "  ",
          styled(
            chunk("  ", bg),
            chunk(text, { fg: palette.dim, ...bg }),
            by !== "" && chunk(by, { fg: palette.faint, ...bg }),
          ),
          `${text}${by}`,
        );
      }),
    ];
  };

  /**
   * A diagram's source: a code block in "mermaid", or a Mermaid fence the page keeps as
   * written (indented, or with a space before its language).
   */
  const mermaidSource = (block: SpaceBlock) =>
    block.kind === "code" && block.language?.toLowerCase() === "mermaid"
      ? block.text
      : block.kind === "raw"
        ? mermaidFenceSource(block.text)
        : null;

  /** A Mermaid diagram: drawn in characters by the MC, or its source. */
  const diagramRows = (block: SpaceBlock, source: string): TuiSpaceRow[] => {
    const key = `block:${block.id}`;
    const active = selected[view] === key;
    const bg = active ? { bg: palette.selectedBg } : {};
    const room = width() - 2;
    const agent = agentOf(block);
    const { lines } = mermaidLines(source, diagrams.get(source), palette, room);
    return lines.map((line, index) => {
      const first = index === 0;
      const lead = first ? marker(active) : "  ";
      const by = index === lines.length - 1 && agent ? `  · ${agent}` : "";
      // A drawing fits the pane; a line of source or a reason is cut to it, as raw text is.
      const parts =
        line.chunks.length === 1
          ? [{ ...line.chunks[0]!, text: clip(expandTabs(line.chunks[0]!.text), room) }]
          : line.chunks;
      const text = parts.map((part) => part.text).join("");
      return {
        key,
        kind: "block",
        text: `${lead}${text}${by}`,
        line: styled(
          chunk(lead, { fg: palette.dim, ...bg }),
          ...parts.map((part) => ({ ...part, ...bg })),
          by !== "" && chunk(by, { fg: palette.faint, ...bg }),
        ),
        selected: active,
        blockKind: block.kind,
        first,
      } satisfies TuiSpaceRow;
    });
  };

  /**
   * A placed image in words. Its caption names it once the image is gone from the stream.
   * An image by its address is never fetched: its caption and where it is.
   */
  const imagePlaceholder = (block: SpaceBlock): string => {
    if (block.url) return `[image${block.text ? `: ${block.text}` : ""}] ${block.url}`;
    const image = imageById(block.imageId);
    if (!image) return `[image: ${block.text} was deleted]`;
    if (image.trashedAt !== null) return `[image: ${image.name} is in the trash]`;
    const caption = block.text === image.name ? "" : ` ${block.text}`;
    return `[image: ${image.name}]${caption}`;
  };

  /** A listed image: its name, and what it was generated from. */
  const imageText = (image: SpaceImage) =>
    image.prompt ? `${image.name}  · ${image.prompt}` : image.name;

  /**
   * Markdown the page keeps as written: a row per source line behind a gutter, with
   * its leading spaces and never wrapped, so a table or code lines up as in the file.
   * A line wider than the pane is cut short; the block's text stays whole.
   */
  // Markdown the page keeps as written is its source, and so are a table and a code block
  // until they are drawn as such (#854).
  const asSource = (block: SpaceBlock) =>
    block.kind === "raw" || block.kind === "table" || block.kind === "code";

  const rawRows = (block: SpaceBlock): TuiSpaceRow[] => {
    const key = `block:${block.id}`;
    const active = selected[view] === key;
    const bg = active ? { bg: palette.selectedBg } : {};
    const agent = agentOf(block);
    const room = width() - 2 - Bun.stringWidth(RAW_GUTTER);
    const lines = block.text.split("\n").map(expandTabs);
    return lines.map((source, index) => {
      const first = index === 0;
      const lead = `${first ? marker(active) : "  "}${RAW_GUTTER}`;
      const text = clip(source, room);
      const by = index === lines.length - 1 && agent ? `  · ${agent}` : "";
      return {
        key,
        kind: "block",
        text: `${lead}${text}${by}`,
        line: styled(
          chunk(lead, { fg: palette.faint, ...bg }),
          chunk(text === "" ? " " : text, { fg: palette.text, ...bg }),
          by !== "" && chunk(by, { fg: palette.faint, ...bg }),
        ),
        selected: active,
        blockKind: block.kind,
        first,
      } satisfies TuiSpaceRow;
    });
  };

  const blockRows = (block: SpaceBlock): TuiSpaceRow[] => {
    // A chart this client cannot read shows what it says of itself, as any block does.
    const chart = block.kind === "chart" ? chartData(block.chart) : null;
    if (chart) return chartRows(block, chart);
    const diagram = mermaidSource(block);
    if (diagram !== null) return diagramRows(block, diagram);
    if (asSource(block)) return rawRows(block);
    const key = `block:${block.id}`;
    const active = selected[view] === key;
    const linked = block.kind === "subpage_link" ? pageById(block.linkedPageId) : undefined;
    const level = block.kind === "heading" ? (block.level ?? 2) : 0;
    const prefix =
      block.kind === "heading"
        ? `${"#".repeat(level)} `
        : block.kind === "checklist"
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
        : block.kind === "image"
          ? imagePlaceholder(block)
          : block.text;
    const agent = block.kind === "generated" ? "written by its update" : agentOf(block);
    const room = width() - 2 - Bun.stringWidth(prefix);
    const lines = wrapWords(body === "" ? " " : body, room);
    // A terminal has one size of type, so a heading's weight steps down with its level.
    const fg =
      block.kind === "heading"
        ? level <= 2
          ? palette.accent
          : level <= 4
            ? palette.text
            : palette.dim
        : block.kind === "subpage_link"
          ? palette.accent
          : block.kind === "callout"
            ? palette.warning
            : (block.kind === "checklist" && block.checked) || block.kind === "image"
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
          chunk(text, { fg, bold: block.kind === "heading", underline: level === 1, ...bg }),
          by !== "" && chunk(by, { fg: palette.faint, ...bg }),
        ),
        selected: active,
        blockKind: block.kind,
        checked: block.checked,
        first,
      } satisfies TuiSpaceRow;
    });
  };

  /** A note above a page's blocks, wrapped. Not selectable. */
  const noteRows = (key: string, text: string, fg: typeof palette.text): TuiSpaceRow[] =>
    wrapWords(text, width() - 2).map((line, index) => {
      const drawn = `  ${line}`;
      return {
        key: `label:${key}`,
        kind: "label",
        text: drawn,
        line: styled(chunk(drawn, { fg })),
        selected: false,
        first: index === 0,
      };
    });

  const projectTitle = (projectId: string) =>
    options.projects?.().find((project) => project.id === projectId)?.title ?? "its project";

  /** The project file the open page is: its path, that it is gone, and what the file won over. */
  const fileRows = (page: SpacePage): TuiSpaceRow[] => {
    const file = page.file;
    if (!file) return [];
    return [
      ...noteRows(
        "file:path",
        `File: ${file.path} of ${projectTitle(file.projectId)} · f opens it`,
        palette.dim,
      ),
      ...(file.missing
        ? noteRows(
            "file:missing",
            "The file is gone: the page keeps what it said, and follows the file when it comes back.",
            palette.warning,
          )
        : []),
      ...(file.conflictAt
        ? noteRows(
            "file:conflict",
            `The file changed under your edit (${clockText(file.conflictAt)}): what you typed is a version in the page's history · h`,
            palette.warning,
          )
        : []),
    ];
  };

  /** What the open page's update is and how it last went, above its blocks. Not selectable. */
  const updateRows = (page: SpacePage): TuiSpaceRow[] => {
    const update = page.schedule;
    if (!update) return [];
    const note = (key: string, text: string, fg: typeof palette.text) =>
      noteRows(`update:${key}`, text, fg);
    const cadence = cadenceText(update.cadence);
    const when = !isLive(page)
      ? `${cadence} · stopped while this page is in the trash`
      : !update.enabled
        ? `${cadence} · paused`
        : update.nextRunAt
          ? `${cadence} · next run ${clockText(update.nextRunAt)}`
          : cadence;
    const written =
      update.lastRunStatus === "running"
        ? "Writing now…"
        : page.writtenAt
          ? `Last written ${clockText(page.writtenAt)}`
          : "Not written yet";
    return [
      ...note("instruction", `⟳ ${update.instruction}`, palette.text),
      ...note("when", when, palette.dim),
      ...note("written", written, palette.dim),
      ...(update.lastRunStatus === "failed"
        ? note(
            "failed",
            `Last run failed: ${update.lastRunError ?? "unknown error"}`,
            palette.error,
          )
        : []),
    ];
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

  /** The path of the file the page in the history is, for its versions read from it. */
  const fileOfHistory = () => {
    const path = pageById(pageId)?.file?.path;
    return path ? ` ${path}` : "";
  };

  const versionRow = (entry: SpacePageVersion, newest: boolean): TuiSpaceRow => {
    const by =
      entry.author.type === "agent"
        ? (entry.threadTitle ?? "an agent")
        : entry.author.type === "schedule"
          ? "The page's update"
          : entry.author.type === "file"
            ? `The project file${fileOfHistory()}`
            : "You";
    const current = newest ? " · current" : "";
    const source = entry.restoredFromAt ? ` · restored from ${when(entry.restoredFromAt)}` : "";
    return entryRow(
      `version:${entry.version}`,
      "version",
      `${when(entry.at)}  ${by}${current}${source}`,
    );
  };

  /** A slide in its deck: its number and title, then its body. */
  const slideRows = (slide: SpaceSlide, index: number): TuiSpaceRow[] => {
    const key = `slide:${slide.id}`;
    const active = selected.deck === key;
    const bg = active ? { bg: palette.selectedBg } : {};
    const head = clip(`${marker(active)}${index + 1}. ${slide.title || UNTITLED}`, width());
    const lead = "     ";
    const room = width() - lead.length;
    const body =
      slide.body === ""
        ? []
        : slide.body.split("\n").flatMap((line) => wrapWords(line === "" ? " " : line, room));
    return [
      {
        key,
        kind: "slide",
        text: head,
        line: styled(
          chunk(head, { fg: slide.title === "" ? palette.dim : palette.text, bold: true, ...bg }),
        ),
        selected: active,
        first: true,
      },
      ...body.map((line): TuiSpaceRow => ({
        key,
        kind: "slide",
        text: `${lead}${line}`,
        line: styled(chunk(`${lead}${line}`, { fg: palette.dim, ...bg })),
        selected: active,
        first: false,
      })),
    ];
  };

  /** The slide on show as text: its title, then its body. Nothing here is selected. */
  const presenterRows = (): TuiSpaceRow[] => {
    const slide = slidesOf(deckId)[shownIndex];
    if (!slide) return [];
    const row = (text: string, style: Parameters<typeof chunk>[1]): TuiSpaceRow => ({
      key: `label:${text}`,
      kind: "label",
      text,
      line: styled(chunk(text, style)),
      selected: false,
      first: true,
    });
    const lines = slide.body === "" ? [] : slide.body.split("\n");
    return [
      row(slide.title || UNTITLED, { fg: palette.accent, bold: true }),
      row(" ", { fg: palette.text }),
      ...lines
        .flatMap((line) => wrapWords(line === "" ? " " : line, width()))
        .map((line) => row(line, { fg: palette.text })),
    ];
  };

  /** What the open page says about its site: the link, and what the reader would miss. */
  const siteRows = (id: string): TuiSpaceRow[] => {
    const site = siteOf(id);
    if (!site) return [];
    return [
      label(`Site: ${site.url}`),
      ...(site.behind ? [label(SITE_BEHIND_HINT)] : []),
      ...(site.localOnly ? [label(SITE_LOCAL_ONLY_HINT)] : []),
    ];
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
      const liveDecks = decks().filter((deck) => deck.trashedAt === null);
      if (liveDecks.length > 0) {
        rows.push(label("Decks"));
        for (const deck of liveDecks) rows.push(entryRow(`deck:${deck.id}`, "deck", deck.title));
      }
      const bin = trashed();
      const deckBin = decks().filter((deck) => deck.trashedAt !== null);
      if (bin.length > 0 || deckBin.length > 0) {
        rows.push(label("Trash"));
        for (const page of bin) {
          rows.push(entryRow(`trash:${page.id}`, "trashed", page.title, {}, palette.dim));
        }
        for (const deck of deckBin) {
          rows.push(entryRow(`decktrash:${deck.id}`, "trashed", deck.title, {}, palette.dim));
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
    if (view === "deck") return slidesOf(deckId).flatMap(slideRows);
    if (view === "present") return presenterRows();
    if (view === "images") {
      const rows = liveImages().map((image) =>
        entryRow(`image:${image.id}`, "image", imageText(image)),
      );
      const bin = trashedImages();
      if (bin.length > 0) {
        rows.push(label("Trash"));
        for (const image of bin) {
          rows.push(
            entryRow(`imageTrash:${image.id}`, "trashedImage", imageText(image), {}, palette.dim),
          );
        }
      }
      return rows;
    }
    const id = pageId;
    if (id === null) return [];
    const comments = commentsOf(id);
    const blocks = blocksOf(id);
    const open = pageById(id);
    const rows: TuiSpaceRow[] = [
      ...(open ? fileRows(open) : []),
      ...(open ? updateRows(open) : []),
      ...siteRows(id),
    ];
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
    if (view === "deck" || view === "present") {
      const deck = deckById(deckId);
      if (view === "present") {
        const position = `${shownIndex + 1} / ${slidesOf(deckId).length}`;
        return `present · ${deck?.title ?? ""} · ${position}`;
      }
      return `deck · ${deck?.title ?? ""}${deck?.trashedAt ? " · in the trash" : ""}`;
    }
    if (view === "images") return `images · ${name}`;
    const page = pageById(pageId);
    if (view === "history") return `history · ${page?.title ?? ""}`;
    if (view === "version") {
      return `version · ${reading?.title ?? ""} · ${reading ? when(reading.at) : ""}`;
    }
    const from = page?.sourceThreadId ? ` · from ${threadTitle(page.sourceThreadId)}` : "";
    const bin = page && !isLive(page) ? " · in the trash" : "";
    const site = siteOf(pageId);
    const published = site ? (site.behind ? " · published, behind" : " · published") : "";
    return `page · ${page?.title ?? ""}${from}${bin}${published}`;
  };

  // An error as a sentence's middle: a provider's own text may end its sentence already.
  const agentError = (error: string | null | undefined): string =>
    clip((error ?? "").replace(/[.\s]+$/, ""), AGENT_ERROR_MOST);

  /** What the open page says about its agent, and the keys that go with it. */
  const agentText = (agent: SpacePageAgent): string => {
    const title = options.threads().find((thread) => thread.id === agent.threadId)?.title;
    const open = `o opens ${title ? `“${title}”` : "its thread"}`;
    switch (agent.status) {
      case "running":
        return `An agent is working on “${clip(agent.request, AGENT_REQUEST_MOST)}” · s stops · ${open}`;
      case "stopping":
        return `Stopping the agent… · s stops · ${open}`;
      case "completed":
        return `The agent finished ${agent.edited ? "and changed" : "without changing"} this page. · ${open} · z clears`;
      case "failed":
        return `The agent failed: ${agentError(agent.error)}. The page stays as it last wrote it. · h history · ${open} · z clears`;
      case "stopped":
        return `${agent.error ? `The agent stopped: ${agentError(agent.error)}.` : "The agent was stopped."} · h history · ${open} · z clears`;
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
    followViewers();
    syncPrompt();
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
            ? "No pages yet · n makes one · s makes a deck · i imports Markdown · t writes one from a thread"
            : view === "version"
              ? "This version has no blocks"
              : view === "deck"
                ? "This deck has no slides · n adds one"
                : view === "images"
                  ? "No images yet · n generates one · i adds one from a file"
                  : "An empty page · n adds a block";
    }
    if (status === "ready" && view === "page") {
      const agent = agentOfPage(pageId);
      if (agent) {
        message = agentText(agent);
        if (agent.status === "failed") status = "error";
      }
    }
    // Window the rows around the selection, under a message that may wrap and who else is here.
    const messageRows = message === "" ? 0 : wrapWords(message, width()).length;
    const room = Math.max(
      1,
      options.height() - SPACE_CHROME_ROWS - messageRows - (viewers === "" ? 0 : 1),
    );
    const first = rows.findIndex((row) => row.selected);
    const last = rows.findLastIndex((row) => row.selected);
    if (first >= 0 && last - first + 1 > room) {
      top = Math.max(first, Math.min(top, last - room + 1));
    } else if (first >= 0) {
      if (first < top) top = first;
      if (last >= top + room) top = Math.max(0, Math.min(first, last - room + 1));
    }
    top = Math.max(0, Math.min(top, Math.max(0, rows.length - room)));
    rowsOnShow = room;
    options.publish({
      open: true,
      view,
      title: titleText(),
      hint: HINTS[view],
      status,
      viewers,
      message,
      rows: rows.slice(top, top + room),
    });
  };
  const stopDiagrams = diagrams.listen(() => {
    if (open) publish();
  });

  // --- streams ---

  // Being subscribed is being on the page, so only while the page shows.
  const followViewers = () => {
    const wanted = open && view === "page" && spaceId !== null ? pageId : null;
    if (wanted === viewersPage) return;
    unsubscribeViewers?.();
    unsubscribeViewers = null;
    viewersPage = wanted;
    viewers = "";
    if (wanted === null) return;
    let live = true;
    const stop = client.subscribeSpacePresence(
      spaceId as SpaceId,
      wanted as SpacePageId,
      (next) => {
        if (!live) return;
        const names = next.flatMap((viewer) =>
          viewer.type === "user" ? viewer.devices : [`the agent of “${viewer.title}”`],
        );
        viewers = names.length === 0 ? "" : `Also here: ${names.join(", ")}`;
        publish();
      },
    );
    unsubscribeViewers = () => {
      live = false;
      stop();
    };
  };

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
    if ((view === "deck" || view === "present") && space.ready && !deckById(deckId)) {
      deckId = null;
      generation += 1;
      view = "pages";
      top = 0;
    }
    if (view === "present") followShownSlide();
    publish();
  };

  /** Stays on the slide on show, or the one at its place if it went; a deck that went stops it. */
  const followShownSlide = () => {
    const slides = slidesOf(deckId);
    if (slides.length === 0 || deckById(deckId)?.trashedAt) {
      view = "deck";
      top = 0;
      return;
    }
    const at = slides.findIndex((slide) => slide.id === shownSlideId);
    shownIndex = at >= 0 ? at : Math.min(shownIndex, slides.length - 1);
    shownSlideId = slides[shownIndex]!.id;
  };

  // --- navigation ---

  const openSpace = (id: string, then: TuiSpaceView = "pages") => {
    generation += 1;
    if (spaceId !== id) {
      spaceId = id;
      selected.pages = null;
      selectedIndex.pages = 0;
      selected.images = null;
      selectedIndex.images = 0;
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
      nextKind = "paragraph";
    }
    pageId = id;
    prompting = false;
    selected.pages = key;
    view = "page";
    top = 0;
    publish();
    askTarget();
    // A file may have changed with nothing watching it (an editor, a pull): read it again.
    // What it brings shows on the stream; a refusal leaves the page as it was.
    if (pageById(id)?.file && spaceId !== null) {
      call(WS_METHODS.spacePageSyncFile, { spaceId, pageId: id }).catch(() => {});
    }
  };

  /** Opens a deck; `key` is its row in the list (a trashed deck's is `decktrash:<id>`). */
  const openDeck = (id: string, key = `deck:${id}`) => {
    generation += 1;
    if (deckId !== id) {
      selected.deck = null;
      selectedIndex.deck = 0;
    }
    deckId = id;
    selected.pages = key;
    view = "deck";
    top = 0;
    publish();
  };

  /** Shows a deck's first slide, or says why it cannot. */
  const present = () => {
    const entry = selectedEntry();
    const id =
      view === "deck"
        ? deckId
        : entry?.kind === "deck" || entry?.kind === "decktrash"
          ? entry.id
          : null;
    if (id === null) {
      options.status("Select a deck to present it.", "info");
      return;
    }
    const slides = slidesOf(id);
    if (deckById(id)?.trashedAt) {
      options.status("Restore this deck from the trash to present it.", "info");
    } else if (slides.length === 0) {
      options.status("This deck has no slides to present.", "info");
    } else {
      if (view !== "deck") openDeck(id);
      shownSlideId = slides[0]!.id;
      shownIndex = 0;
      view = "present";
      top = 0;
      publish();
    }
  };

  /** One slide on or back; stops at either end. */
  const stepSlide = (by: number) => {
    const slides = slidesOf(deckId);
    const next = Math.max(0, Math.min(slides.length - 1, shownIndex + by));
    if (next === shownIndex) return;
    shownIndex = next;
    shownSlideId = slides[next]!.id;
    top = 0;
    publish();
  };

  const leavePresenter = () => {
    view = "deck";
    top = 0;
    publish();
  };

  const showImages = () => {
    if (view === "images" || view === "present" || view === "history" || view === "version") return;
    if (view === "spaces") {
      options.status("Open a Space to see its images.", "info");
      return;
    }
    imagesFrom = view;
    view = "images";
    top = 0;
    publish();
  };

  const leaveSpace = () => {
    generation += 1;
    closeHistory();
    stopSpace();
    spaceId = null;
    pageId = null;
    deckId = null;
    prompting = false;
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
    if (view === "images") {
      view =
        imagesFrom === "page" && pageById(pageId)
          ? "page"
          : imagesFrom === "deck" && deckById(deckId)
            ? "deck"
            : "pages";
      top = 0;
      publish();
    } else if (view === "version") {
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
    } else if (view === "page" || view === "deck") {
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
    const rows = allRows();
    const keys = entryKeys(rows);
    if (keys.length === 0) return;
    // The rest of an entry taller than the pane comes before the next entry.
    const first = rows.findIndex((row) => row.selected);
    const last = rows.findLastIndex((row) => row.selected);
    if (first >= 0 && last - first + 1 > rowsOnShow) {
      const within = Math.max(first, Math.min(last - rowsOnShow + 1, top + delta));
      if (within !== top) {
        top = within;
        publish();
        return;
      }
    }
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
          // A refresh that stopped at a row already held joins up with the older rows;
          // one that stopped short of them leaves a gap, so they go.
          const joined = current.versions.findIndex((row) => row.version === result.nextBefore);
          const older = joined >= 0 ? current.versions.slice(joined + 1) : [];
          if (more) {
            current.versions = [...current.versions, ...result.versions];
            current.nextBefore = result.nextBefore;
          } else if (older.length > 0) {
            current.versions = [...result.versions, ...older];
          } else {
            current.versions = result.versions;
            current.nextBefore = result.nextBefore;
          }
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
    else if (entry.kind === "deck") openDeck(entry.id);
    else if (entry.kind === "decktrash") {
      openDeck(entry.id, `decktrash:${entry.id}`);
      options.status("This deck is in the trash: r restores it.", "info");
    } else if (entry.kind === "slide") edit();
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
    } else if (entry.kind === "image" || entry.kind === "imageTrash") {
      options.status("A terminal cannot draw an image; the desktop and the phone show it.", "info");
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
    else if (view === "deck") addSlide();
    else if (view === "images") askGenerateImage();
    else addBlock();
  };

  const newDeck = () => {
    const id = spaceId;
    if (view !== "pages" || id === null) {
      options.status("Open a Space to make a deck in it.", "info");
      return;
    }
    const asked = generation;
    options.ask({
      label: "new deck",
      placeholder: "title",
      onSubmit: (title) => {
        void send<{ deck: SpaceDeck }>(WS_METHODS.spaceDeckCreate, { spaceId: id, title }).then(
          (result) => {
            if (result && asked === generation && spaceId === id) openDeck(result.deck.id);
          },
        );
      },
    });
  };

  /** A deck copied from the open page or the one selected; the MC refuses one in the trash. */
  const deckFromPage = () => {
    const id = spaceId;
    const page = pageInView();
    if (id === null || page === null) {
      options.status("Open or select a page to make a deck from it.", "info");
      return;
    }
    const asked = generation;
    void send<{ deck: SpaceDeck }>(WS_METHODS.spaceDeckCreateFromPage, {
      spaceId: id,
      pageId: page,
    }).then((result) => {
      if (result && asked === generation && spaceId === id) openDeck(result.deck.id);
    });
  };

  /** A new slide after the selected one, or last with none selected. */
  const addSlide = () => {
    const id = spaceId;
    const deck = deckId;
    if (id === null || deck === null) return;
    const entry = selectedEntry();
    const after = entry?.kind === "slide" ? entry.id : null;
    const asked = generation;
    options.ask({
      label: "new slide",
      placeholder: "title",
      onSubmit: (title) => {
        void send<{ slide: SpaceSlide }>(WS_METHODS.spaceSlideInsert, {
          spaceId: id,
          deckId: deck,
          title,
          body: "",
          ...(after === null ? {} : { afterSlideId: after }),
        }).then((result) => {
          if (result && asked === generation && deckId === deck) {
            selected.deck = `slide:${result.slide.id}`;
            publish();
          }
        });
      },
    });
  };

  /** Its title, then its body on one line; Esc at the body keeps the new title. */
  const editSlide = (id: string) => {
    const slide = slidesOf(deckId).find((candidate) => candidate.id === id);
    if (!slide) return;
    const body = bodyToField(slide.body);
    options.ask({
      label: "slide title",
      value: slide.title,
      onSubmit: (title) => {
        if (title !== slide.title) {
          void send(WS_METHODS.spaceSlideUpdate, { spaceId, slideId: id, title });
        }
        options.ask({
          label: "slide body, \\n for a new line",
          value: body,
          onSubmit: (text) => {
            // The answer comes trimmed: a body left as it was is not an edit.
            if (text !== body.trim()) {
              void send(WS_METHODS.spaceSlideUpdate, {
                spaceId,
                slideId: id,
                body: bodyFromField(text),
              });
            }
          },
        });
      },
    });
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

  /** Adds a block where a new one goes and selects it; rejects with the MC's refusal. */
  const placeBlock = async (input: Record<string, unknown>) => {
    const id = spaceId;
    const page = pageId;
    if (id === null || page === null) return;
    const after = anchorBlock();
    const asked = generation;
    const result = await call<{ block: SpaceBlock }>(WS_METHODS.spaceBlockInsert, {
      spaceId: id,
      pageId: page,
      ...input,
      ...(after === null ? {} : { afterBlockId: after }),
    });
    if (asked === generation && pageId === page) {
      selected.page = `block:${result.block.id}`;
      publish();
    }
  };

  const insertBlock = (input: Record<string, unknown>) => {
    placeBlock(input).catch((error: unknown) => options.status(refusalText(error), "error"));
  };

  const addBlock = () => {
    options.menu({
      title: "Add a block",
      options: [
        ...BLOCK_KINDS.map((entry) => ({ label: entry.label, value: entry.kind })),
        { label: "Ask an agent", description: "about this page, in the prompt", value: "ask" },
      ],
      onChoose: (value) => {
        if (value === "ask") {
          askAgent();
          return;
        }
        const kind = value as SpaceBlockKind;
        if (kind === "subpage_link") {
          link();
          return;
        }
        if (kind === "chart") {
          visualize(false);
          return;
        }
        if (kind === "image") {
          placeImage();
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

  /**
   * Asks the MC for a chart in the user's words. On a chart it asks again, starting from
   * the words that chart was asked for in, and replaces it; elsewhere a new chart goes
   * where a new block would, as it always does from the add menu (`again` false). The MC
   * draws it or says why not, and the stream shows it.
   */
  const visualize = (again = true) => {
    const id = spaceId;
    const page = pageId;
    if (view !== "page" || id === null || page === null) {
      options.status("Open a page to ask for a chart.", "info");
      return;
    }
    const entry = selectedEntry();
    const replacing =
      again && entry?.kind === "block"
        ? blocksOf(page).find((block) => block.id === entry.id && block.kind === "chart")
        : undefined;
    const asked = generation;
    options.ask({
      label: replacing ? "ask again" : "chart",
      placeholder: "what should it show?",
      ...(replacing ? { value: chartData(replacing.chart)?.request ?? "" } : {}),
      onSubmit: (request) => startChart(id, page, request, replacing?.id ?? null, asked),
    });
  };

  /**
   * Draws a chart without waiting on it: a model draws it, so nothing holds the keys
   * meanwhile. The status line says when it is drawn, or why it was not.
   */
  const startChart = (...args: Parameters<typeof drawChart>) => {
    drawChart(...args).catch((error: unknown) => options.status(refusalText(error), "error"));
  };

  /** Asks the MC for a chart in `request`, replacing `blockId`'s; rejects with its refusal. */
  const drawChart = async (
    id: string,
    page: string,
    request: string,
    blockId: string | null,
    asked: number,
  ) => {
    const after = blockId === null ? anchorBlock() : null;
    options.status("Drawing a chart…", "info");
    const result = await call<{ block: SpaceBlock }>(WS_METHODS.spaceBlockVisualize, {
      spaceId: id,
      pageId: page,
      request,
      ...(blockId === null ? {} : { blockId }),
      ...(after === null ? {} : { afterBlockId: after }),
    });
    options.status(`Drew “${chartData(result.block.chart)?.title ?? "a chart"}”.`, "info");
    if (asked === generation && pageId === page) {
      selected.page = `block:${result.block.id}`;
      publish();
    }
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

  /** Every image: the MC refuses one in the trash, and says why. */
  const placeImage = () => {
    if (images().length === 0) {
      options.status("This Space has no images yet: v shows them, to add one.", "info");
      return;
    }
    options.menu({
      title: "Place an image",
      searchable: true,
      options: [
        ...liveImages().map((image) => ({ label: image.name, value: image.id })),
        ...trashedImages().map((image) => ({
          label: `${image.name} (in the trash)`,
          value: image.id,
        })),
      ],
      onChoose: (imageId) => insertBlock({ kind: "image", imageId }),
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
    } else if (entry.kind === "deck" || entry.kind === "decktrash") {
      options.ask({
        label: "rename deck",
        value: deckById(entry.id)?.title ?? "",
        onSubmit: (title) => {
          void send(WS_METHODS.spaceDeckRename, { spaceId, deckId: entry.id, title });
        },
      });
    } else if (entry.kind === "slide") {
      editSlide(entry.id);
    } else if (entry.kind === "block") {
      const id = spaceId;
      const block = blocksOf(pageId ?? "").find((candidate) => candidate.id === entry.id);
      if (block?.kind === "subpage_link") {
        options.status("A link shows its page's title: rename the page instead.", "info");
        return;
      }
      if (block?.kind === "generated") {
        options.status(
          "A page's update wrote this, so it cannot be edited: removing the update (u) keeps it to edit.",
          "info",
        );
        return;
      }
      if (block?.kind === "chart") {
        visualize();
        return;
      }
      if (block && asSource(block)) {
        // As written, spaces and all: a source line's indent is part of its Markdown.
        const source = bodyToField(block.text);
        options.ask({
          label: "edit Markdown, \\n for a new line",
          value: source,
          untrimmed: true,
          onSubmit: (text) => {
            if (text !== source) {
              void send(WS_METHODS.spaceBlockUpdate, {
                spaceId: id,
                blockId: entry.id,
                text: bodyFromField(text),
              });
            }
          },
        });
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
    } else if (entry.kind === "deck") {
      void send(WS_METHODS.spaceDeckTrash, { spaceId: id, deckId: entry.id }).then((result) => {
        if (result) options.status("Moved to the trash: r restores it.", "info");
      });
    } else if (entry.kind === "trash" || entry.kind === "decktrash") {
      deleteForGood();
    } else if (entry.kind === "slide") {
      void send(WS_METHODS.spaceSlideDelete, { spaceId: id, slideId: entry.id });
    } else if (entry.kind === "block") {
      void send(WS_METHODS.spaceBlockDelete, { spaceId: id, blockId: entry.id });
    } else if (entry.kind === "comment") {
      options.status("Comments are resolved, not deleted: x resolves or reopens.", "info");
    } else if (entry.kind === "image") {
      void send(WS_METHODS.spaceImageTrash, { spaceId: id, imageId: entry.id }).then((result) => {
        if (result) options.status("Moved to the trash: r restores it.", "info");
      });
    } else if (entry.kind === "imageTrash") {
      deleteForGood();
    }
  };

  /**
   * Deletes the selected page and its subpages for good, once confirmed. Only a page
   * in the trash can go; the MC says so for one that is not.
   */
  const deleteForGood = () => {
    const entry = selectedEntry();
    const id = spaceId;
    if (view === "pages" && (entry?.kind === "deck" || entry?.kind === "decktrash")) {
      options.menu({
        title: `Delete “${deckById(entry.id)?.title ?? "this deck"}” for good, with its slides?`,
        options: [
          { label: entry.kind === "decktrash" ? "Keep it in the trash" : "Keep it", value: "keep" },
          { label: "Delete for good", value: "delete" },
        ],
        onChoose: (value) => {
          if (value === "delete") {
            void send(WS_METHODS.spaceDeckDelete, { spaceId: id, deckId: entry.id });
          }
        },
      });
      return;
    }
    if (view === "images") {
      if (entry) deleteImageForGood(entry);
      return;
    }
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

  /** Once confirmed. Only an image in the trash can go; the MC says so for one that is not. */
  const deleteImageForGood = (entry: { readonly kind: string; readonly id: string }) => {
    const id = spaceId;
    const name = imageById(entry.id)?.name ?? "this image";
    options.menu({
      title: `Delete “${name}” for good? Pages showing it will say it was deleted.`,
      options: [
        { label: entry.kind === "imageTrash" ? "Keep it in the trash" : "Keep it", value: "keep" },
        { label: "Delete for good", value: "delete" },
      ],
      onChoose: (value) => {
        if (value === "delete") {
          void send(WS_METHODS.spaceImageDelete, { spaceId: id, imageId: entry.id });
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
    if (view === "images") {
      if (entry?.kind === "imageTrash") {
        void send(WS_METHODS.spaceImageRestore, { spaceId, imageId: entry.id });
      } else options.status("Only an image in the trash can be restored.", "info");
    } else if (entry?.kind === "trash") {
      void send(WS_METHODS.spacePageRestore, { spaceId, pageId: entry.id });
    } else if (entry?.kind === "decktrash") {
      void send(WS_METHODS.spaceDeckRestore, { spaceId, deckId: entry.id });
    } else if (view === "deck") {
      if (deckById(deckId)?.trashedAt) {
        void send(WS_METHODS.spaceDeckRestore, { spaceId, deckId });
      } else options.status("Only a deck in the trash can be restored.", "info");
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

  /** A, the palette and the add menu: the page's prompt takes the keys, as an ask. */
  const askAgent = () => {
    const page = pageId;
    if (view !== "page" || page === null) return;
    const current = agentOfPage(page);
    if (current && isActive(current)) {
      options.status("An agent is already working on this page: s stops it.", "info");
      return;
    }
    focusPrompt(true);
    options.askInPrompt?.();
  };

  /** Runs `fn` on the open page's agent; a page without one says so. */
  const withAgent = (fn: (agent: SpacePageAgent) => void) => () => {
    if (view !== "page") return;
    const agent = agentOfPage(pageId);
    if (agent) fn(agent);
    else options.status("No agent was asked on this page: A asks one.", "info");
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
          : target.kind === "image"
            ? imagePlaceholder(target)
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
    } else if (entry.kind === "slide") {
      const slides = slidesOf(deckId);
      const slide = slides.find((candidate) => candidate.id === entry.id);
      if (!slide) return;
      const others = slides.filter((candidate) => candidate.id !== slide.id);
      options.menu({
        title: `Move “${slide.title || UNTITLED}”`,
        options: [
          ...others.map((target) => ({
            label: `Before “${target.title || UNTITLED}”`,
            value: target.id,
          })),
          { label: "To the end", value: "" },
        ],
        onChoose: (before) => {
          // Before a slide is after the one ahead of it, first when there is none.
          const index = others.findIndex((target) => target.id === before);
          const afterSlideId =
            before === "" ? (others.at(-1)?.id ?? null) : index > 0 ? others[index - 1]!.id : null;
          void send(WS_METHODS.spaceSlideMove, { spaceId, slideId: slide.id, afterSlideId });
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

  const publishSite = (tailscale: boolean) => {
    const page = pageInView();
    if (page === null) {
      options.status("Open or select a page to publish it as a site.", "info");
      return;
    }
    const title = pageById(page)?.title ?? "the page";
    // A link made on loopback is no use to anyone else, so the address that reached
    // this MC goes along, as for a pairing link. Tailscale names its own.
    const origin = options.origin ?? "";
    const reached = origin !== "" && !loopbackHost(new URL(origin).hostname);
    void send<{ site: SpaceSite }>(WS_METHODS.spacePagePublish, {
      spaceId,
      pageId: page,
      ...(tailscale ? { tailscale: true } : reached ? { baseUrl: origin } : {}),
    }).then((result) => {
      if (result) options.status(`Published “${title}” at ${result.site.url}`, "info");
    });
  };

  const copySiteLink = () => {
    const site = siteOf(pageInView());
    if (!site) {
      options.status("This page is not published.", "info");
      return;
    }
    if (options.copy?.(site.url) === true) options.status("Site link copied.", "info");
    else options.status("This terminal cannot reach the clipboard.", "warning");
  };

  const unpublishSite = () => {
    const page = pageInView();
    if (!siteOf(page)) {
      options.status("This page is not published.", "info");
      return;
    }
    void send(WS_METHODS.spacePageUnpublish, { spaceId, pageId: page }).then((result) => {
      if (result) options.status("Unpublished: the link no longer opens.", "info");
    });
  };

  /** `p`: presents the deck in view or selected, and publishes a page. */
  const presentOrPublish = () => {
    const kind = selectedEntry()?.kind;
    if (view === "page" || (view === "pages" && kind !== "deck" && kind !== "decktrash")) {
      publishSite(false);
    } else {
      present();
    }
  };

  /** The palette's way to what p, P, Y and u do on the page in view. */
  const siteCommands = (): Array<{ title: string; action: string }> => {
    const site = siteOf(pageInView());
    return [
      { title: site ? "Publish again" : "Publish as a site", action: "space.publish" },
      { title: "Publish over Tailscale", action: "space.publishTailscale" },
      ...(site
        ? [
            { title: "Copy site link", action: "space.copySiteLink" },
            { title: "Unpublish", action: "space.unpublish" },
          ]
        : []),
    ];
  };

  const addImageFile = () => {
    const id = spaceId;
    const read = options.readLocalBytes;
    if (id === null) return;
    if (!read) {
      options.status("Images cannot be read on this device.", "error");
      return;
    }
    const asked = generation;
    options.ask({
      label: "add image file",
      placeholder: "path on this machine",
      onSubmit: (path) => {
        void track(uploadImage(id, path, read, asked));
      },
    });
  };

  const uploadImage = async (
    id: string,
    path: string,
    read: NonNullable<SpaceControllerOptions["readLocalBytes"]>,
    asked: number,
  ) => {
    const name = NodePath.basename(path);
    let bytes: Uint8Array;
    try {
      bytes = await read(path, PROVIDER_SEND_TURN_MAX_IMAGE_BYTES);
    } catch (error) {
      options.status(
        `Could not read ${path}: ${error instanceof Error ? error.message : String(error)}`,
        "error",
      );
      return;
    }
    const mimeType = imageTypeOf(bytes);
    if (mimeType === null) {
      options.status(`${name} is not a PNG, JPEG, GIF or WebP image.`, "error");
      return;
    }
    options.status(`Adding “${name}”…`, "info");
    let attachmentId: string;
    try {
      const upload = await call<{ attachmentId: string; relativeUrl: string }>(
        WS_METHODS.attachmentsCreateUploadUrl,
        { name, mimeType, sizeBytes: bytes.length },
      );
      await client.uploadToMc(upload.relativeUrl, bytes, mimeType);
      attachmentId = upload.attachmentId;
    } catch (error) {
      options.status(refusalText(error), "error");
      return;
    }
    const result = await send<{ image: SpaceImage }>(WS_METHODS.spaceImageAdd, {
      spaceId: id,
      attachmentId,
      name,
    });
    if (!result) return;
    options.status(`Added “${result.image.name}”.`, "info");
    selectNewImage(result.image, asked, id);
  };

  const selectNewImage = (image: SpaceImage, asked: number, id: string) => {
    if (asked === generation && spaceId === id && view === "images") {
      selected.images = `image:${image.id}`;
      publish();
    }
  };

  const askGenerateImage = () => {
    const id = spaceId;
    if (id === null) return;
    options.ask({
      label: "generate an image",
      placeholder: "what should it show?",
      onSubmit: (prompt) => {
        void chooseImageProvider(id, prompt);
      },
    });
  };

  /**
   * With a choice, asks which provider draws it, naming the ones that cannot; the
   * model is that provider's default. Without one the MC picks, or says why it cannot.
   */
  const chooseImageProvider = async (id: string, prompt: string) => {
    const offer = await send<SpaceImageProvidersResult>(WS_METHODS.spaceImageProviders, {});
    if (!offer) return;
    if (offer.providers.filter((provider) => provider.status === "ready").length < 2) {
      generateImage(id, prompt);
      return;
    }
    const chosen = offer.selection;
    options.menu({
      title: "Who should draw it?",
      index: Math.max(
        0,
        offer.providers.findIndex((provider) => provider.instanceId === chosen?.instanceId),
      ),
      options: offer.providers.map((provider) => ({
        label: provider.instanceId,
        value: provider.instanceId,
        disabled: provider.status !== "ready",
        description:
          provider.status === "ready"
            ? ""
            : provider.status === "unsupported"
              ? "not supported here"
              : (provider.message ?? "unavailable"),
      })),
      onChoose: (instanceId) =>
        generateImage(id, prompt, instanceId === chosen?.instanceId ? chosen : { instanceId }),
    });
  };

  const generateImage = (id: string, prompt: string, modelSelection?: object) => {
    const asked = generation;
    options.status("Generating an image…", "info");
    void send<{ image: SpaceImage }>(WS_METHODS.spaceImageGenerate, {
      spaceId: id,
      prompt,
      ...(modelSelection ? { modelSelection } : {}),
    }).then((result) => {
      if (!result) return;
      options.status(`Generated “${result.image.name}”.`, "info");
      selectNewImage(result.image, asked, id);
    });
  };

  const importMarkdown = () => {
    const id = spaceId;
    if (view === "images") {
      addImageFile();
      return;
    }
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

  const setUpdate = (id: string, instruction: string, cadence: unknown) => {
    void send(WS_METHODS.spacePageScheduleSet, { spaceId, pageId: id, instruction, cadence });
  };

  /** The instruction, then the cadence. A time the MC cannot read comes back as its refusal. */
  const askUpdate = (id: string, update: SpacePageSchedule | null | undefined) => {
    options.ask({
      label: update ? "change the update" : "have this page update itself",
      placeholder: "Summarise yesterday's threads",
      value: update?.instruction ?? "",
      onSubmit: (instruction) => {
        options.menu({
          title: "How often?",
          options: [
            ...(update ? [{ label: `Keep: ${cadenceText(update.cadence)}`, value: "keep" }] : []),
            ...[1, 2, 6, 12].map((hours) => ({
              label: cadenceText({ type: "interval", everyMs: hours * HOUR_MS }),
              value: String(hours),
            })),
            { label: "At a time of day…", value: "time" },
          ],
          onChoose: (choice) => {
            const held = update?.cadence;
            if (choice === "keep") setUpdate(id, instruction, held);
            else if (choice === "time") {
              const fixed = held?.type === "fixed_time" ? held : undefined;
              options.ask({
                label: "time of day",
                placeholder: "09:00",
                value: fixed?.timeOfDay ?? "09:00",
                onSubmit: (timeOfDay) =>
                  setUpdate(id, instruction, {
                    type: "fixed_time",
                    timeOfDay,
                    weekdays: fixed?.weekdays ?? [],
                  }),
              });
            } else
              setUpdate(id, instruction, { type: "interval", everyMs: Number(choice) * HOUR_MS });
          },
        });
      },
    });
  };

  /** The open page's update: gives it one, or what can be done with the one it has. */
  const pageUpdate = () => {
    const open = view === "page" ? pageById(pageId) : undefined;
    if (!open) {
      options.status("Open a page to have it update itself.", "info");
      return;
    }
    if (!isLive(open)) {
      options.status("This page is in the trash: r restores it.", "info");
      return;
    }
    const update = open.schedule;
    if (!update) {
      askUpdate(open.id, update);
      return;
    }
    const target = { spaceId, pageId: open.id };
    options.menu({
      title: "This page's update",
      options: [
        { label: "Run it now", value: "run" },
        { label: update.enabled ? "Pause it" : "Resume it", value: "pause" },
        { label: "Change it…", value: "change" },
        { label: "Remove it, keeping what it wrote", value: "remove" },
      ],
      onChoose: (choice) => {
        if (choice === "change") askUpdate(open.id, update);
        else if (choice === "pause") {
          void send(WS_METHODS.spacePageScheduleSetEnabled, {
            ...target,
            enabled: !update.enabled,
          });
        } else if (choice === "remove") void send(WS_METHODS.spacePageScheduleRemove, target);
        else if (update.lastRunStatus === "running") {
          options.status("This page's update is running already.", "info");
        } else void send(WS_METHODS.spacePageScheduleRunNow, target);
      },
    });
  };

  // --- project files ---

  // Which files of each project the MC counts as Space content, as it last said; null while asked.
  const spaceFiles = new Map<string, ReadonlySet<string> | null>();

  const knowSpaceFiles = (projectId: string, result: SpaceFilesListResult) => {
    spaceFiles.set(projectId, new Set(result.files.map((file) => file.relativePath)));
    options.commandsChanged?.();
  };

  const refreshSpaceFiles = (projectId: string) => {
    spaceFiles.set(projectId, null);
    call<SpaceFilesListResult>(WS_METHODS.spaceFilesList, { projectId }).then(
      (result) => knowSpaceFiles(projectId, result),
      // Not known, so the next look asks again.
      () => spaceFiles.delete(projectId),
    );
  };

  /** Why a file did not open, in words. */
  const fileRefusalText = (error: unknown, path: string): string => {
    const { tag, reason } = refusal(error);
    if (tag !== "SpaceError") return refusalText(error);
    if (reason === "notSpaceFile") {
      return `${path} is not Space content: the spaces section of the project's hal-c2.json does not name it.`;
    }
    if (reason === "notFound") return `${path} is not in the project.`;
    if (reason === "invalid") return `${path} is outside the project.`;
    return refusalText(error);
  };

  /** Opens a project's file as a page of the project's own Space and shows it. */
  const openProjectFile = (projectId: string, path: string) => {
    void track(
      (async () => {
        let result: SpacePageOpenFileResult;
        try {
          result = await call<SpacePageOpenFileResult>(WS_METHODS.spacePageOpenFile, {
            projectId,
            relativePath: path,
          });
        } catch (error) {
          options.status(fileRefusalText(error, path), "error");
          return;
        }
        closeHistory();
        show();
        openSpace(result.spaceId);
        openPage(result.page.id);
        options.status(
          result.created
            ? `Opened ${path} as the page “${result.page.title}”.`
            : `${path} is the page “${result.page.title}”.`,
          "info",
        );
      })(),
    );
  };

  /** Picks one of this MC's projects; one alone is picked without asking. */
  const pickProject = (title: string, then: (projectId: string) => void) => {
    const projects = options.projects?.() ?? [];
    if (projects.length === 0) {
      options.status("There are no projects on this machine.", "info");
    } else if (projects.length === 1) {
      then(projects[0]!.id);
    } else {
      options.menu({
        title,
        searchable: true,
        options: projects.map((project) => ({ label: project.title, value: project.id })),
        onChoose: then,
      });
    }
  };

  /**
   * Picks a project's Space file and opens it, among `only` when given (the paths a
   * message names, one of which opens without asking).
   */
  const pickFile = (projectId: string, only?: ReadonlyArray<string>) => {
    void send<SpaceFilesListResult>(WS_METHODS.spaceFilesList, { projectId }).then((result) => {
      if (!result) return;
      knowSpaceFiles(projectId, result);
      const files = only
        ? result.files.filter((file) => only.includes(file.relativePath))
        : result.files;
      const name = projectTitle(projectId);
      if (files.length === 0) {
        options.status(
          only
            ? `None of the files it names is Space content in ${name}.`
            : result.config === "invalid"
              ? `The spaces section of ${name}'s hal-c2.json does not match the format, so no file is Space content.`
              : `${name} has no Space files.`,
          "info",
        );
      } else if (only && files.length === 1) {
        openProjectFile(projectId, files[0]!.relativePath);
      } else {
        options.menu({
          title: `Open a file of ${name} as a page`,
          searchable: true,
          options: files.map((file) => ({
            label: file.relativePath,
            value: file.relativePath,
            ...(file.page ? { description: `the page “${file.page.title}”` } : {}),
          })),
          onChoose: (path) => openProjectFile(projectId, path),
        });
      }
    });
  };

  /** `space.openProjectFile {projectId?, path?, paths?}`: opens it, or asks what's missing. */
  const openFileFrom = (payload: unknown) => {
    const { projectId, path, paths } = (payload ?? {}) as {
      readonly projectId?: unknown;
      readonly path?: unknown;
      readonly paths?: unknown;
    };
    const only = Array.isArray(paths)
      ? paths.filter((entry): entry is string => typeof entry === "string")
      : undefined;
    const then = (id: string) => {
      if (typeof path === "string") openProjectFile(id, path);
      else pickFile(id, only);
    };
    if (typeof projectId !== "string") pickProject("Open a file of which project?", then);
    else if ((options.projects?.() ?? []).some((project) => project.id === projectId)) {
      then(projectId);
    } else {
      // Its files open in its own machine's Spaces, which this pane does not follow (#860).
      options.status(
        "That project is on another machine: its files open in that machine's Spaces.",
        "info",
      );
    }
  };

  /** From the pages: one of a project's files, edited as a page of the project's Space. */
  const fromFiles = () => {
    pickProject("Edit a file of which project as a page?", (projectId) => pickFile(projectId));
  };

  /** From a page to its file, in the file viewer. */
  const showPageFile = () => {
    const file = pageById(pageId)?.file;
    if (!file) {
      options.status("This page is not a project file.", "info");
    } else if (file.missing) {
      options.status(`${file.path} is gone from the project.`, "info");
    } else options.showFile?.(file.projectId, file.path);
  };

  /** Proposes the project's spaces section and writes it, or offers replacing one someone wrote. */
  const scanFiles = (projectId: string, replace = false) => {
    const name = projectTitle(projectId);
    void send<SpaceFilesScanResult>(WS_METHODS.spaceFilesScan, {
      projectId,
      ...(replace ? { replace: true } : {}),
    }).then((result) => {
      if (!result) return;
      refreshSpaceFiles(projectId);
      const entries = clip(result.entries.map((entry) => entry.path).join(", "), 120);
      if (result.status === "written") {
        options.status(`Wrote the spaces section of ${name}'s hal-c2.json: ${entries}.`, "success");
      } else if (result.status === "current") {
        options.status(
          `The spaces section of ${name}'s hal-c2.json already says ${entries}.`,
          "info",
        );
      } else if (result.status === "empty") {
        options.status(`${name} has no Markdown to count, so nothing was written.`, "info");
      } else {
        options.menu({
          title: `${name}'s hal-c2.json has a spaces section someone wrote`,
          options: [
            { label: "Keep it", value: "keep" },
            { label: `Replace it with the scan's: ${entries}`, value: "replace" },
          ],
          onChoose: (choice) => {
            if (choice === "replace") scanFiles(projectId, true);
          },
        });
      }
    });
  };

  const scanFrom = (payload: unknown) => {
    const { projectId } = (payload ?? {}) as { readonly projectId?: unknown };
    if (typeof projectId === "string") scanFiles(projectId);
    else pickProject("Scan which project for Space files?", (id) => scanFiles(id));
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

  const page = (delta: number) => move(delta * rowsOnShow);

  /** A slide longer than the pane scrolls; `publish` keeps it in range. */
  const scrollSlide = (delta: number) => {
    top = Math.max(0, top + delta * Math.max(1, options.height() - SPACE_CHROME_ROWS));
    publish();
  };

  // The keys while a slide is on show. Those not here do nothing until the user leaves.
  const presenterActions: Record<string, () => void> = {
    "space.next": () => stepSlide(1),
    "space.activate": () => stepSlide(1),
    "space.tick": () => stepSlide(1),
    "space.previous": () => stepSlide(-1),
    "space.back": () => stepSlide(-1),
    "space.pageUp": () => scrollSlide(-1),
    "space.pageDown": () => scrollSlide(1),
    "space.leave": leavePresenter,
  };

  // --- the page's prompt ---

  const focusPrompt = (on: boolean) => {
    if (prompting === on) return;
    prompting = on;
    publish();
  };

  /** Where the MC would run an ask that names no project; the prompt shows it. */
  const askTarget = () => {
    void call<SpacePageAgentTarget>(WS_METHODS.spacePageAgentTarget, {}).then(
      (result) => {
        if (result.projectId === agentTarget) return;
        agentTarget = result.projectId;
        publish();
      },
      () => {},
    );
  };

  /** What "/" chose: the words that start the prompt, or null when a menu takes over. */
  const chooseKind = (value: string): string | null => {
    const kind = value as SpaceBlockKind;
    if (kind === "chart") return "/visualize ";
    if (kind === "subpage_link") {
      link();
      return null;
    }
    if (kind === "image") {
      placeImage();
      return null;
    }
    if (nextKind !== kind) {
      nextKind = kind;
      publish();
    }
    return "";
  };

  /**
   * What the prompt sent: `@agent …` asks an agent with the prompt's choices, `/visualize …`
   * asks for a chart, anything else is a block of the kind "/" chose. Resolves to why the
   * page refused it, or null once it is written; the prompt keeps a refused draft.
   */
  const submitPrompt = async (page: string, input: PagePrompt): Promise<string | null> => {
    const id = spaceId;
    if (id === null || pageId !== page) return "The page is no longer open.";
    try {
      const ask = ASK_PREFIX.exec(input.text);
      if (ask) {
        const current = agentOfPage(page);
        if (current && isActive(current)) {
          return "An agent is already working on this page: s stops it.";
        }
        await call(WS_METHODS.spacePageAskAgent, {
          spaceId: id,
          pageId: page,
          request: input.text.slice(ask[0].length),
          ...(input.projectId === null ? {} : { projectId: input.projectId }),
          ...(input.modelSelection === null ? {} : { modelSelection: input.modelSelection }),
          runtimeMode: input.runtimeMode,
          interactionMode: input.interactionMode,
          ...(input.attachments.length > 0 ? { attachments: input.attachments } : {}),
        });
        return null;
      }
      if (input.attachments.length > 0) {
        return "Images go with an ask: start the prompt with @agent.";
      }
      const chart = VISUALIZE_PREFIX.exec(input.text);
      if (chart) {
        startChart(id, page, input.text.slice(chart[0].length), null, generation);
        return null;
      }
      const kind = nextKind;
      await placeBlock({ kind, text: input.text });
      // A heading or a callout is one block; a paragraph or a checklist goes on.
      if (kind === "heading" || kind === "callout") {
        nextKind = "paragraph";
        publish();
      }
      return null;
    } catch (error) {
      return refusalText(error);
    }
  };

  /** Rebuilds `pagePrompt`, telling the prompt when what it aims at changed. */
  const syncPrompt = () => {
    const page = open && view === "page" && spaceId !== null ? pageById(pageId) : undefined;
    const agent = page ? agentOfPage(page.id) : undefined;
    const agentActive = agent ? isActive(agent) : false;
    const signature = page
      ? [spaceId, page.id, page.title, nextKind, agentTarget, agentActive, prompting].join("\u0000")
      : "";
    if (signature === promptSignature) return;
    promptSignature = signature;
    pagePrompt = page
      ? {
          key: `page:${spaceId}:${page.id}`,
          title: page.title || UNTITLED,
          writes: PROMPT_WRITES[nextKind] ?? "writes a paragraph",
          agentActive,
          defaultProjectId: agentTarget,
          projects: () => options.projects?.() ?? [],
          kinds: PROMPT_KINDS,
          chooseKind,
          submit: (input) => submitPrompt(page.id, input),
          stop: stopAgent,
          leave: () => focusPrompt(false),
        }
      : null;
    options.promptChanged?.();
  };

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
    // ^P: on a page its prompt takes the keys, and gives them back; elsewhere it closes.
    "space.prompt": inView(() => (pagePrompt ? focusPrompt(true) : close())),
    "space.focus": inView(() => focusPrompt(false)),
    "space.previous": inView(() => move(-1)),
    "space.next": inView(() => move(1)),
    "space.pageUp": inView(() => page(-1)),
    "space.pageDown": inView(() => page(1)),
    "space.activate": inView(activate),
    "space.back": inView(back),
    "space.leave": inView(back),
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
    "space.newDeckOrStopAgent": onPages(() => (view === "page" ? stopAgent() : newDeck())),
    "space.dismissAgent": onPages(dismissAgent),
    "space.openAgentThread": onPages(openAgentThread),
    "space.move": onPages(moveEntry),
    "space.link": onPages(link),
    "space.export": onPages(exportMarkdown),
    "space.publish": onPages(() => publishSite(false)),
    "space.publishTailscale": onPages(() => publishSite(true)),
    "space.copySiteLink": onPages(copySiteLink),
    "space.unpublish": onPages(unpublishSite),
    "space.import": onPages(importMarkdown),
    "space.fromThread": onPages(fromThread),
    "space.update": onPages(pageUpdate),
    "space.visualize": onPages(visualize),
    "space.newDeck": onPages(newDeck),
    "space.deckFromPage": onPages(deckFromPage),
    "space.present": onPages(present),
    "space.presentOrPublish": onPages(presentOrPublish),
    "space.images": onPages(showImages),
    "space.files": onPages(() => (view === "page" ? showPageFile() : fromFiles())),
    // From anywhere: the palette, the file browser and viewer, a message's links.
    "space.openProjectFile": (payload) => {
      openFileFrom(payload);
      return true;
    },
    "space.scanFiles": (payload) => {
      scanFrom(payload);
      return true;
    },
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
    dispatch: (action, payload) => {
      if (open && view === "present" && !["space.close", "space.toggle"].includes(action)) {
        const run = presenterActions[action];
        if (run) run();
        if (run || action in actions) return true;
      }
      return actions[action]?.(payload) ?? false;
    },
    close,
    isOpen: () => open,
    mode: () => (prompting && pagePrompt ? "pagePrompt" : "space"),
    prompt: () => pagePrompt,
    sync: () => {
      if (open) publish();
    },
    connectionLost: () => {
      if (viewers === "") return;
      viewers = "";
      publish();
    },
    commands: () => {
      const entries: SpaceCommand[] = [
        { title: open ? "Close Spaces" : "Spaces", action: open ? "space.close" : "space.open" },
      ];
      if ((options.projects?.() ?? []).length > 0) {
        entries.push(
          { title: "Open a project file in a Space…", action: "space.openProjectFile" },
          { title: "Scan a project for Space files…", action: "space.scanFiles" },
        );
      }
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
          { title: "Add a page from a project's files", action: "space.files" },
          { title: "Copy page as Markdown", action: "space.export" },
          { title: "Page history", action: "space.history" },
          { title: "New deck", action: "space.newDeck" },
          { title: "Make a deck from the selected page", action: "space.deckFromPage" },
          { title: "Present the selected deck", action: "space.present" },
          ...siteCommands(),
          { title: "Images in this Space", action: "space.images" },
        );
      } else if (view === "deck") {
        entries.push(
          { title: "Add a slide", action: "space.new" },
          { title: "Edit slide", action: "space.edit" },
          { title: "Move slide", action: "space.move" },
          { title: "Delete slide", action: "space.delete" },
          { title: "Present deck", action: "space.present" },
          { title: "Restore deck from the trash", action: "space.restore" },
          { title: "Images in this Space", action: "space.images" },
        );
      } else if (view === "present") {
        entries.push(
          { title: "Next slide", action: "space.next" },
          { title: "Previous slide", action: "space.previous" },
          { title: "Leave the presenter", action: "space.leave" },
        );
      } else if (view === "images") {
        entries.push(
          { title: "Generate an image", action: "space.new" },
          { title: "Add an image from a file", action: "space.import" },
          { title: "Move image to the trash", action: "space.delete" },
          { title: "Restore image from the trash", action: "space.restore" },
          { title: "Delete image for good", action: "space.deleteForGood" },
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
          {
            title: "Ask for a chart, or ask again for the selected one",
            action: "space.visualize",
          },
          { title: "Edit block", action: "space.edit" },
          { title: "Move block", action: "space.move" },
          { title: "Delete block", action: "space.delete" },
          { title: "Tick / untick, resolve / reopen", action: "space.tick" },
          { title: "Comment on the block", action: "space.comment" },
          { title: "Link a subpage", action: "space.link" },
          { title: "This page's update", action: "space.update" },
          { title: "Copy page as Markdown", action: "space.export" },
          { title: "Make a deck from this page", action: "space.deckFromPage" },
          { title: "Restore page from the trash", action: "space.restore" },
          { title: "Page history", action: "space.history" },
          ...siteCommands(),
          { title: "Images in this Space", action: "space.images" },
        );
        if (pageById(pageId)?.file) {
          entries.push({ title: "Show the page's file", action: "space.files" });
        }
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
    isSpaceFile: (projectId, path) => {
      if (!spaceFiles.has(projectId)) refreshSpaceFiles(projectId);
      return spaceFiles.get(projectId)?.has(path) ?? false;
    },
    refreshSpaceFiles,
    settled: async () => {
      while (pending.size > 0) await Promise.allSettled(pending);
      await diagrams.settled();
    },
    dispose: () => {
      stopDiagrams();
      unsubscribeViewers?.();
      unsubscribeViewers = null;
      unsubscribeSpaces?.();
      unsubscribeSpaces = null;
      closeHistory();
      stopSpace();
    },
  };
}
