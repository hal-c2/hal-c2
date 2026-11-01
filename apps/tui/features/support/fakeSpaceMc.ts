// The MC's Spaces, faked in memory under the rules of HalC2.Space (space.ex,
// space/pages.ex, space/blocks.ex, space/order.ex, space/markdown.ex): the
// `space.*` RPCs a client sends, and the `spaces` and `space:<id>` streams it
// follows. One fake serves every client of a scenario, so a second client sees
// the first one's edits as they land; `restart` sends each watcher a fresh
// snapshot, as a reconnection after an MC restart does.
import type { SpaceAuthor, SpacePresenceViewer } from "@hal-c2/contracts";
import type { EntityStreamFrame } from "@hal-c2/client-runtime/state/stream-entities";

import type { FakeSettingsMc } from "./fakeSettingsMc.ts";

type Entity = Record<string, any>;
type Patch = { s?: Entity; d?: true };
type Change = readonly [kind: string, id: string, patch: Patch];

/** A refusal as the MC's socket sends it: the message, and the tagged detail. */
export class FakeSpaceRefusal extends Error {
  readonly detail: { readonly _tag: string; readonly reason: string };
  constructor(tag: string, reason: string, message: string) {
    super(message);
    this.detail = { _tag: tag, reason };
  }
}

const refuse = (reason: string, message: string): never => {
  throw new FakeSpaceRefusal("SpaceError", reason, message);
};

export type FakeGeneration =
  | { readonly kind: "available"; readonly title: string; readonly markdown: string }
  | { readonly kind: "unavailable"; readonly message: string }
  | { readonly kind: "failed"; readonly message: string };

export type FakeImageGeneration =
  | { readonly kind: "available" }
  | { readonly kind: "unavailable"; readonly message: string }
  | { readonly kind: "failed"; readonly message: string };

// HalC2.Space.ImageFile.check, as far as a scenario needs: the content decides.
const imageMime = (bytes: Uint8Array): string | null => {
  const text = String.fromCharCode(...bytes.subarray(0, 12));
  if (text.startsWith("\x89PNG")) return "image/png";
  if (text.startsWith("\xff\xd8\xff")) return "image/jpeg";
  if (text.startsWith("GIF8")) return "image/gif";
  if (text.startsWith("RIFF") && text.slice(8) === "WEBP") return "image/webp";
  return null;
};

interface Watcher {
  readonly onFrame: (frame: EntityStreamFrame) => void;
}

export interface FakeSpaceMc {
  /** Serve this client's `space.*` calls and streams from this MC. */
  readonly attach: (settings: FakeSettingsMc) => void;
  /** Run a `space.*` method as the given author (an agent's MCP tools write as their thread). */
  readonly run: (method: string, payload: Entity, author?: SpaceAuthor) => any;
  readonly spaceNamed: (name: string) => Entity;
  readonly pageNamed: (title: string) => Entity;
  readonly blockNamed: (text: string) => Entity;
  readonly commentNamed: (body: string) => Entity;
  readonly imageNamed: (name: string) => Entity;
  readonly imagesOf: (spaceId: string) => Entity[];
  /** An image already in the Space, as if uploaded earlier. */
  readonly seedImage: (spaceId: string, name: string) => Entity;
  readonly spaces: () => Entity[];
  readonly pagesOf: (spaceId: string) => Entity[];
  readonly blocksOf: (pageId: string) => Entity[];
  readonly commentsOf: (pageId: string) => Entity[];
  /** What text generation does when a page is made from a thread. */
  generation: FakeGeneration;
  /** What image generation does. */
  imageGeneration: FakeImageGeneration;
  /** Where each summary was written: the folder of the thread the request named. */
  readonly summaries: Array<{ readonly threadId: string; readonly cwd: string | null }>;
  /** What the MC refused clients, newest last. */
  readonly refusals: string[];
  /** Where a site link points; a loopback address makes it local only. */
  siteAddress: string;
  /** The machine's name on the tailnet, null when Tailscale is not up. */
  tailnetName: string | null;
  /** Whether a site link answers at the moment. */
  readonly siteOpens: (url: string) => boolean;
  /** The site a page is published as. */
  readonly siteOf: (title: string) => Entity | undefined;
  /** The changes of the newest `space:<id>` transaction. */
  lastChanges: ReadonlyArray<Change>;
  /** Every watcher gets a fresh snapshot, as after a reconnection. */
  readonly restart: () => void;
  /** Another device comes to the page, and goes from wherever it is. */
  readonly deviceOn: (pageId: string, device: string) => void;
  readonly deviceGone: (device: string) => void;
  /** Answers the followers of every page again, as a reconnect's subscribe does. */
  readonly retellViewers: () => void;
  /** An agent, by its thread's title, comes to the page, and goes from wherever it is. */
  readonly agentOn: (pageId: string, title: string) => void;
  readonly agentGone: (title: string) => void;
  /** How many clients are on the page. */
  readonly clientsOn: (pageId: string) => number;
}

const DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz";
const BASE = DIGITS.length;

/** HalC2.Space.Order.between: a key after `low` and before `high` (null: the start or the end). */
export function orderBetween(low: string | null, high: string | null): string {
  const digits = (key: string) => [...key].map((char) => DIGITS.indexOf(char));
  const commonPrefix = (lo: number[], hi: number[]) => {
    const out: number[] = [];
    for (const [index, digit] of hi.entries()) {
      if ((lo[index] ?? 0) !== digit) break;
      out.push(digit);
    }
    return out;
  };
  const midFirst = (lo: number[], hi: number[] | null): number[] => {
    const a = lo[0] ?? 0;
    const b = hi ? hi[0]! : BASE;
    if (b - a > 1) return [Math.floor((a + b) / 2)];
    if (hi !== null && hi.length > 1) return [b];
    return [a, ...mid(lo.slice(1), null)];
  };
  const mid = (lo: number[], hi: number[] | null): number[] => {
    if (hi === null || hi.length === 0) return midFirst(lo, null);
    const prefix = commonPrefix(lo, hi);
    if (prefix.length === 0) return midFirst(lo, hi);
    return [...prefix, ...mid(lo.slice(prefix.length), hi.slice(prefix.length))];
  };
  return mid(digits(low ?? ""), high === null ? null : digits(high))
    .map((digit) => DIGITS[digit])
    .join("");
}

/** HalC2.Space.Markdown.export. */
function exportMarkdown(page: Entity, blocks: Entity[], titleOf: (id: string) => string | null) {
  const chunks: Entity[][] = [];
  for (const block of blocks) {
    const last = chunks.at(-1);
    if (block.kind === "checklist" && last?.[0]?.kind === "checklist") last.push(block);
    else chunks.push([block]);
  }
  const line = (block: Entity) => {
    switch (block.kind) {
      case "heading":
        return `## ${block.text}`;
      case "checklist":
        return `${block.checked ? "- [x] " : "- [ ] "}${block.text}`;
      case "callout":
        return block.text
          .split("\n")
          .map((text: string) => `> ${text}`.trimEnd())
          .join("\n");
      case "subpage_link":
        return `[${titleOf(block.linkedPageId) ?? block.text}](#${block.linkedPageId})`;
      default:
        return block.text;
    }
  };
  return `${[`# ${page.title}`, ...chunks.map((chunk) => chunk.map(line).join("\n"))].join("\n\n")}\n`;
}

/** HalC2.Space.Markdown.parse: the title and the block specs. */
function parseMarkdown(markdown: string): { title: string | null; blocks: Entity[] } {
  const lines = markdown.replace(/\r\n/g, "\n").split("\n");
  const out: Array<Entity | { title: string }> = [];
  const block = (kind: string, text: string, checked = false) => ({
    kind,
    text,
    checked,
    linkedPageId: null,
  });
  const paragraphLine = (line: string) =>
    line.trim() !== "" && !/^(#{1,6}\s|>|```|\s*[-*]\s+\[[ xX]\])/.test(line);
  let index = 0;
  while (index < lines.length) {
    const line = lines[index]!;
    let match: RegExpExecArray | null;
    if (line.trim() === "") index += 1;
    else if ((match = /^#\s+(.*)$/.exec(line))) {
      out.push({ title: match[1]!.trim() });
      index += 1;
    } else if ((match = /^#{2,6}\s+(.*)$/.exec(line))) {
      out.push(block("heading", match[1]!.trim()));
      index += 1;
    } else if ((match = /^\s*[-*]\s+\[([ xX])\]\s?(.*)$/.exec(line))) {
      out.push(block("checklist", match[2]!, match[1] !== " "));
      index += 1;
    } else if (line.startsWith(">")) {
      const quote: string[] = [];
      while (index < lines.length && lines[index]!.startsWith(">")) {
        quote.push(lines[index]!.slice(1).replace(/^ /, ""));
        index += 1;
      }
      out.push(block("callout", quote.join("\n")));
    } else {
      const paragraph: string[] = [];
      while (index < lines.length && paragraphLine(lines[index]!)) {
        paragraph.push(lines[index]!);
        index += 1;
      }
      if (paragraph.length === 0) {
        paragraph.push(line);
        index += 1;
      }
      out.push(block("paragraph", paragraph.join("\n")));
    }
  }
  const [first, ...rest] = out;
  const untitle = (entry: Entity | { title: string }): Entity =>
    "title" in entry && !("kind" in entry) ? block("heading", entry.title) : (entry as Entity);
  if (first && "title" in first && !("kind" in first)) {
    return { title: first.title, blocks: rest.map(untitle) };
  }
  return { title: null, blocks: out.map(untitle) };
}

/**
 * A fake MC's Spaces. `cwdOf` names the folder a thread's summary is written in
 * (its worktree or its project's), null when the MC has no such thread.
 */
export function fakeSpaceMc(options: { readonly cwdOf: (threadId: string) => string | null }) {
  const spaces = new Map<string, Entity>();
  // Per Space: its pages, blocks and comments, each in creation order.
  const content = new Map<string, Map<string, Map<string, Entity>>>();
  const seqs = new Map<string, number>();
  // What `attachments.createUploadUrl` signed, and the bytes sent to it; an upload is taken once.
  const uploads = new Map<string, { name: string; mimeType: string; bytes: Uint8Array | null }>();
  const watchers = new Map<string, Set<Watcher>>();
  // Who is on each page, and the clients to tell.
  const devicesOn = new Map<string, Set<string>>();
  const agentsOn = new Map<string, Set<string>>();
  const pageClients = new Map<string, Set<(viewers: ReadonlyArray<SpacePresenceViewer>) => void>>();
  const viewersOf = (pageId: string) => {
    const devices = [...(devicesOn.get(pageId) ?? [])].sort();
    const agents = [...(agentsOn.get(pageId) ?? [])];
    return [
      ...(devices.length > 0 ? [{ type: "user", devices }] : []),
      ...agents.map((title) => ({ type: "agent", threadId: `thread-${title}`, title })),
    ] as ReadonlyArray<SpacePresenceViewer>;
  };
  const tellPage = (pageId: string) => {
    for (const client of pageClients.get(pageId) ?? []) client(viewersOf(pageId));
  };
  const on = (who: Map<string, Set<string>>, pageId: string, name: string) => {
    let names = who.get(pageId);
    if (!names) who.set(pageId, (names = new Set()));
    names.add(name);
    tellPage(pageId);
  };
  const gone = (who: Map<string, Set<string>>, name: string) => {
    for (const [pageId, names] of who) if (names.delete(name)) tellPage(pageId);
  };
  let ids = 0;
  let clock = Date.parse("2026-07-15T12:00:00.000Z");
  const user: SpaceAuthor = { type: "user" };

  const now = () => new Date((clock += 1000)).toISOString();
  const nextId = (prefix: string) => `${prefix}-${(ids += 1)}`;

  const kindsOf = (spaceId: string) => {
    let kinds = content.get(spaceId);
    if (!kinds) {
      kinds = new Map([
        ["page", new Map()],
        ["block", new Map()],
        ["comment", new Map()],
        ["site", new Map()],
        ["image", new Map()],
      ]);
      content.set(spaceId, kinds);
    }
    return kinds;
  };
  const table = (spaceId: string, kind: string) => kindsOf(spaceId).get(kind)!;

  const streamRows = (stream: string): Array<readonly [string, string, Entity]> => {
    if (stream === "spaces") return [...spaces.values()].map((s) => ["space", s.id, { ...s }]);
    const spaceId = stream.slice("space:".length);
    if (!spaces.has(spaceId)) return [];
    return [...kindsOf(spaceId)].flatMap(([kind, entities]) =>
      [...entities.values()].map((entity) => [kind, entity.id as string, { ...entity }] as const),
    );
  };

  const snapshot = (stream: string): EntityStreamFrame => ({
    type: "snapshot",
    part: 0,
    done: true,
    offset: seqs.get(stream) ?? 0,
    rows: streamRows(stream),
  });

  /** What a site shows of its page. */
  const siteSnapshot = (spaceId: string, entry: Entity) => ({
    title: entry.title,
    blocks: blocksOf(spaceId, entry.id).map(({ kind, text, checked }) => ({ kind, text, checked })),
  });

  /** A site whose page left goes down; one whose page changed falls behind. */
  const followSites = (spaceId: string): Change[] =>
    [...table(spaceId, "site").values()].flatMap((site): Change[] => {
      const entry = table(spaceId, "page").get(site.pageId);
      if (!entry || !isLive(spaceId, entry)) return [["site", site.id, { d: true }]];
      const behind = JSON.stringify(site.snapshot) !== JSON.stringify(siteSnapshot(spaceId, entry));
      return behind === site.behind ? [] : [["site", site.id, { s: { behind } }]];
    });

  /** Apply one transaction's changes and send them to the stream's watchers as one frame. */
  const commit = (stream: string, changes: ReadonlyArray<Change>) => {
    if (changes.length === 0) return;
    const spaceId = stream === "spaces" ? null : stream.slice("space:".length);
    const at = Date.now();
    const apply = ([kind, id, patch]: Change) => {
      const entities = spaceId === null ? spaces : table(spaceId, kind);
      if (patch.d) entities.delete(id);
      else entities.set(id, { ...entities.get(id), ...patch.s });
      const seq = (seqs.get(stream) ?? 0) + 1;
      seqs.set(stream, seq);
      return [seq, kind, id, patch, at] as const;
    };
    const events = changes.map(apply);
    // A site follows its page in the same transaction, as HalC2.Space.Sites does.
    if (spaceId !== null) events.push(...followSites(spaceId).map(apply));
    if (spaceId !== null) mc.lastChanges = changes;
    for (const watcher of watchers.get(stream) ?? []) {
      watcher.onFrame({ type: "events", events: events as never });
    }
  };

  // --- reads ---

  const space = (id: unknown): Entity =>
    spaces.get(String(id)) ?? refuse("not_found", `There is no Space ${String(id)}.`);
  const pages = (spaceId: string) => [...table(spaceId, "page").values()];
  const page = (spaceId: string, id: unknown): Entity =>
    table(spaceId, "page").get(String(id)) ??
    refuse("not_found", `There is no page ${String(id)} in this Space.`);
  const isLive = (spaceId: string, entry: Entity): boolean => {
    let current: Entity | undefined = entry;
    const seen = new Set<string>();
    while (current) {
      if (current.trashedAt !== null) return false;
      if (current.parentPageId === null || seen.has(current.id)) return true;
      seen.add(current.id);
      current = table(spaceId, "page").get(current.parentPageId);
    }
    return true;
  };
  const livePage = (spaceId: string, id: unknown): Entity => {
    const found = page(spaceId, id);
    if (!isLive(spaceId, found)) refuse("trashed", `The page "${found.title}" is in the trash.`);
    return found;
  };
  const blocksOf = (spaceId: string, pageId: string) =>
    [...table(spaceId, "block").values()]
      .filter((block) => block.pageId === pageId)
      .sort((a, b) => (a.order < b.order ? -1 : a.order > b.order ? 1 : 0));
  const block = (spaceId: string, id: unknown): Entity =>
    table(spaceId, "block").get(String(id)) ??
    refuse("not_found", `There is no block ${String(id)} in this Space.`);
  /** A block on a page that is not in the trash. */
  const liveBlock = (spaceId: string, id: unknown) => {
    const found = block(spaceId, id);
    livePage(spaceId, found.pageId);
    return found;
  };
  const image = (spaceId: string, id: unknown): Entity =>
    table(spaceId, "image").get(String(id)) ??
    refuse("not_found", `There is no image ${String(id)} in this Space.`);
  const descendants = (spaceId: string, id: string): string[] => {
    const children = pages(spaceId)
      .filter((entry) => entry.parentPageId === id)
      .map((entry) => entry.id as string);
    return [...children, ...children.flatMap((child) => descendants(spaceId, child))];
  };

  const name = (value: unknown, what: string) => {
    const text = typeof value === "string" ? value.trim() : "";
    return text === "" ? refuse("invalid", what) : text;
  };

  /** Where a block goes: after `after`, first for null, last when undefined. */
  const orderAt = (spaceId: string, pageId: string, after: unknown, moving?: string): string => {
    const blocks = blocksOf(spaceId, pageId).filter((entry) => entry.id !== moving);
    if (after === undefined) return orderBetween(blocks.at(-1)?.order ?? null, null);
    if (after === null) return orderBetween(null, blocks[0]?.order ?? null);
    if (after === moving) refuse("invalid", "A block cannot go after itself.");
    const index = blocks.findIndex((entry) => entry.id === after);
    if (index < 0) refuse("not_found", `There is no block ${String(after)} on this page.`);
    return orderBetween(blocks[index]!.order, blocks[index + 1]?.order ?? null);
  };

  // --- writes ---

  const newPage = (spaceId: string, title: unknown, parent: unknown, extra: Entity = {}) => {
    const parentPageId = parent ?? null;
    if (parentPageId !== null) livePage(spaceId, parentPageId);
    const at = now();
    const entry = {
      id: nextId("page"),
      spaceId,
      title: name(title, "A page needs a title."),
      parentPageId,
      sourceThreadId: null,
      trashedAt: null,
      createdAt: at,
      updatedAt: at,
      ...extra,
    };
    return { entry, change: ["page", entry.id, { s: entry }] as Change };
  };

  const newBlock = (
    spaceId: string,
    pageId: string,
    spec: Entity,
    order: string,
    by: SpaceAuthor,
  ) => {
    const kinds = ["paragraph", "heading", "checklist", "callout", "subpage_link", "image"];
    if (!kinds.includes(spec.kind)) refuse("invalid", `A block is one of ${kinds.join(", ")}.`);
    if (spec.kind === "subpage_link" && !table(spaceId, "page").get(spec.linkedPageId)) {
      refuse("invalid", "A subpage link needs a page of this Space.");
    }
    const placed = spec.kind === "image" ? image(spaceId, spec.imageId) : null;
    if (placed && placed.trashedAt !== null) {
      refuse("trashed", `The image "${placed.name}" is in the trash.`);
    }
    const at = now();
    const entry = {
      id: nextId("block"),
      pageId,
      kind: spec.kind,
      text: spec.text || placed?.name || "",
      checked: spec.kind === "checklist" && spec.checked === true,
      linkedPageId: spec.kind === "subpage_link" ? spec.linkedPageId : null,
      ...(placed ? { imageId: placed.id } : {}),
      order,
      createdBy: by,
      updatedBy: by,
      createdAt: at,
      updatedAt: at,
    };
    return entry;
  };

  const newImage = (spaceId: string, spec: Entity, by: SpaceAuthor) => {
    const at = now();
    const entry = {
      id: nextId("image"),
      spaceId,
      width: 1,
      height: 1,
      prompt: null,
      generatedBy: null,
      trashedAt: null,
      createdBy: by,
      createdAt: at,
      updatedAt: at,
      ...spec,
    };
    commit(`space:${spaceId}`, [["image", entry.id, { s: entry }]]);
    return { image: entry };
  };

  const importPage = (
    spaceId: string,
    markdown: string,
    title: string | undefined,
    parent: unknown,
    extra: Entity,
    by: SpaceAuthor,
  ) => {
    space(spaceId);
    const parsed = parseMarkdown(markdown);
    const { entry, change } = newPage(spaceId, title ?? parsed.title ?? "Untitled", parent, extra);
    const changes: Change[] = [change];
    let previous: string | null = null;
    for (const spec of parsed.blocks) {
      const order = orderBetween(previous, null);
      previous = order;
      const added = newBlock(spaceId, entry.id, spec, order, by);
      changes.push(["block", added.id, { s: added }]);
    }
    commit(`space:${spaceId}`, changes);
    return { page: entry };
  };

  const newSpace = (spaceName: string) => {
    const at = now();
    return { id: nextId("space"), name: spaceName, createdAt: at, updatedAt: at };
  };

  // Whoever looks first, by listing or by making a Space, finds Personal there.
  const seeded = (): Change[] => {
    if (spaces.size > 0) return [];
    const personal = newSpace("Personal");
    return [["space", personal.id, { s: personal }]];
  };

  const methods: Record<string, (input: Entity, by: SpaceAuthor) => unknown> = {
    "space.list": () => {
      commit("spaces", seeded());
      return { spaces: [...spaces.values()] };
    },
    "space.create": (input) => {
      const entry = newSpace(name(input.name, "A Space needs a name."));
      commit("spaces", [...seeded(), ["space", entry.id, { s: entry }]]);
      return { space: entry };
    },
    "space.rename": (input) => {
      space(input.spaceId);
      const patch = { name: name(input.name, "A Space needs a name."), updatedAt: now() };
      commit("spaces", [["space", input.spaceId, { s: patch }]]);
      return { space: spaces.get(input.spaceId) };
    },
    "space.delete": (input) => {
      space(input.spaceId);
      if (pages(input.spaceId).length > 0 || table(input.spaceId, "image").size > 0) {
        refuse("not_empty", "Empty the Space, trash included, before deleting it.");
      }
      commit("spaces", [["space", input.spaceId, { d: true }]]);
      content.delete(input.spaceId);
      return { spaceId: input.spaceId };
    },
    "space.page.create": (input) => {
      space(input.spaceId);
      const { entry, change } = newPage(input.spaceId, input.title, input.parentPageId);
      commit(`space:${input.spaceId}`, [change]);
      return { page: entry };
    },
    "space.page.rename": (input) => {
      const found = livePage(input.spaceId, input.pageId);
      const patch = { title: name(input.title, "A page needs a title."), updatedAt: now() };
      commit(`space:${input.spaceId}`, [["page", found.id, { s: patch }]]);
      return { page: table(input.spaceId, "page").get(found.id) };
    },
    "space.page.move": (input) => {
      const found = livePage(input.spaceId, input.pageId);
      const parent = input.parentPageId ?? null;
      if (parent !== null) {
        livePage(input.spaceId, parent);
        if (parent === found.id || descendants(input.spaceId, found.id).includes(parent)) {
          refuse("cycle", "A page cannot move inside itself.");
        }
      }
      commit(`space:${input.spaceId}`, [
        ["page", found.id, { s: { parentPageId: parent, updatedAt: now() } }],
      ]);
      return { page: table(input.spaceId, "page").get(found.id) };
    },
    "space.page.trash": (input) => {
      const found = livePage(input.spaceId, input.pageId);
      commit(`space:${input.spaceId}`, [["page", found.id, { s: { trashedAt: now() } }]]);
      return { page: table(input.spaceId, "page").get(found.id) };
    },
    "space.page.restore": (input) => {
      const found = page(input.spaceId, input.pageId);
      if (found.trashedAt === null) {
        refuse("invalid", `The page "${found.title}" is not in the trash.`);
      }
      const parent = found.parentPageId && table(input.spaceId, "page").get(found.parentPageId);
      const keep = parent && isLive(input.spaceId, parent);
      commit(`space:${input.spaceId}`, [
        [
          "page",
          found.id,
          { s: { trashedAt: null, parentPageId: keep ? parent.id : null, updatedAt: now() } },
        ],
      ]);
      return { page: table(input.spaceId, "page").get(found.id) };
    },
    "space.page.delete": (input) => {
      const found = page(input.spaceId, input.pageId);
      if (found.trashedAt === null) {
        refuse(
          "invalid",
          `Only a page in the trash can be deleted; move "${found.title}" there first.`,
        );
      }
      const gone = new Set([found.id as string, ...descendants(input.spaceId, found.id)]);
      const goneBlocks = new Set(
        [...table(input.spaceId, "block").values()]
          .filter((entry) => gone.has(entry.pageId) || gone.has(entry.linkedPageId))
          .map((entry) => entry.id as string),
      );
      const comments = [...table(input.spaceId, "comment").values()].filter(
        (entry) => gone.has(entry.pageId) || goneBlocks.has(entry.blockId),
      );
      commit(`space:${input.spaceId}`, [
        ...[...gone].map((id) => ["page", id, { d: true }] as Change),
        ...[...goneBlocks].map((id) => ["block", id, { d: true }] as Change),
        ...comments.map((entry) => ["comment", entry.id, { d: true }] as Change),
      ]);
      return { deletedPageIds: [...gone] };
    },
    "space.page.publish": (input) => {
      const found = livePage(input.spaceId, input.pageId);
      const sites = table(input.spaceId, "site");
      const existing = [...sites.values()].find((site) => site.pageId === found.id);
      if (input.tailscale && mc.tailnetName === null) {
        refuse("unavailable", "Tailscale cannot publish the site.");
      }
      const address = input.tailscale
        ? `https://${mc.tailnetName}`
        : (input.baseUrl ?? mc.siteAddress);
      const id = existing?.id ?? nextId("token");
      commit(`space:${input.spaceId}`, [
        [
          "site",
          id,
          {
            s: {
              id,
              spaceId: input.spaceId,
              pageId: found.id,
              url: `${address}/sites/${input.spaceId}/${id}`,
              localOnly: /\/\/(localhost|127\.)/.test(address),
              publishedAt: now(),
              behind: false,
              snapshot: siteSnapshot(input.spaceId, found),
            },
          },
        ],
      ]);
      return { site: sites.get(id) };
    },
    "space.page.unpublish": (input) => {
      const found = page(input.spaceId, input.pageId);
      const site = [...table(input.spaceId, "site").values()].find(
        (entry) => entry.pageId === found.id,
      );
      if (site) commit(`space:${input.spaceId}`, [["site", site.id, { d: true }]]);
      return { pageId: found.id };
    },
    "space.page.exportMarkdown": (input) => {
      const found = page(input.spaceId, input.pageId);
      const titleOf = (id: string) => table(input.spaceId, "page").get(id)?.title ?? null;
      return { markdown: exportMarkdown(found, blocksOf(input.spaceId, found.id), titleOf) };
    },
    "space.page.importMarkdown": (input, by) => {
      if (typeof input.markdown !== "string") refuse("invalid", "markdown is a string.");
      return importPage(input.spaceId, input.markdown, input.title, input.parentPageId, {}, by);
    },
    "space.page.createFromThread": (input) => {
      space(input.spaceId);
      const cwd = options.cwdOf(input.threadId);
      if (cwd === null) {
        refuse(
          "not_found",
          `There is no thread ${input.threadId} with a project folder on this MC.`,
        );
      }
      mc.summaries.push({ threadId: input.threadId, cwd });
      const generation = mc.generation;
      if (generation.kind !== "available") {
        throw new FakeSpaceRefusal("SpaceTextGenerationError", generation.kind, generation.message);
      }
      const agent: SpaceAuthor = { type: "agent", threadId: input.threadId };
      return importPage(
        input.spaceId,
        generation.markdown,
        generation.title.trim() === "" ? undefined : generation.title,
        input.parentPageId,
        { sourceThreadId: input.threadId },
        agent,
      );
    },
    "space.block.insert": (input, by) => {
      const target = livePage(input.spaceId, input.pageId);
      const order = orderAt(input.spaceId, target.id, input.afterBlockId);
      const added = newBlock(input.spaceId, target.id, input, order, by);
      commit(`space:${input.spaceId}`, [["block", added.id, { s: added }]]);
      return { block: added };
    },
    "space.block.update": (input, by) => {
      const found = liveBlock(input.spaceId, input.blockId);
      if (typeof input.text !== "string") refuse("invalid", "A block's text is a string.");
      commit(`space:${input.spaceId}`, [
        ["block", found.id, { s: { text: input.text, updatedBy: by, updatedAt: now() } }],
      ]);
      return { block: table(input.spaceId, "block").get(found.id) };
    },
    "space.block.setChecked": (input, by) => {
      const found = liveBlock(input.spaceId, input.blockId);
      if (found.kind !== "checklist") refuse("invalid", "Only a checklist item can be ticked.");
      commit(`space:${input.spaceId}`, [
        [
          "block",
          found.id,
          { s: { checked: input.checked === true, updatedBy: by, updatedAt: now() } },
        ],
      ]);
      return { block: table(input.spaceId, "block").get(found.id) };
    },
    "space.block.move": (input, by) => {
      const found = liveBlock(input.spaceId, input.blockId);
      const order = orderAt(input.spaceId, found.pageId, input.afterBlockId, found.id);
      commit(`space:${input.spaceId}`, [
        ["block", found.id, { s: { order, updatedBy: by, updatedAt: now() } }],
      ]);
      return { block: table(input.spaceId, "block").get(found.id) };
    },
    "space.block.delete": (input) => {
      const found = liveBlock(input.spaceId, input.blockId);
      const comments = [...table(input.spaceId, "comment").values()].filter(
        (entry) => entry.blockId === found.id,
      );
      commit(`space:${input.spaceId}`, [
        ["block", found.id, { d: true }],
        ...comments.map((entry) => ["comment", entry.id, { d: true }] as Change),
      ]);
      return { blockId: found.id };
    },
    "space.comment.add": (input, by) => {
      const target = livePage(input.spaceId, input.pageId);
      const blockId = input.blockId ?? null;
      if (blockId !== null && block(input.spaceId, blockId).pageId !== target.id) {
        refuse("not_found", `There is no block ${blockId} on this page.`);
      }
      const at = now();
      const entry = {
        id: nextId("comment"),
        pageId: target.id,
        blockId,
        author: by,
        body: name(input.body, "A comment needs a body."),
        resolvedAt: null,
        createdAt: at,
        updatedAt: at,
      };
      commit(`space:${input.spaceId}`, [["comment", entry.id, { s: entry }]]);
      return { comment: entry };
    },
    "attachments.createUploadUrl": (input) => {
      const attachmentId = nextId("attachment");
      uploads.set(attachmentId, { name: input.name, mimeType: input.mimeType, bytes: null });
      return { attachmentId, relativeUrl: `/api/attachments/upload/${attachmentId}` };
    },
    "space.image.add": (input, by) => {
      space(input.spaceId);
      const upload = uploads.get(input.attachmentId);
      if (!upload?.bytes) return refuse("invalid", "That upload is not there.");
      uploads.delete(input.attachmentId);
      const mimeType = imageMime(upload.bytes);
      if (mimeType === null) refuse("invalid", "That file is not an image.");
      return newImage(
        input.spaceId,
        {
          name: name(input.name ?? upload.name, "An image needs a name."),
          mimeType,
          sizeBytes: upload.bytes.length,
        },
        by,
      );
    },
    "space.image.generate": (input, by) => {
      space(input.spaceId);
      const prompt = name(input.prompt, "An image needs a prompt.");
      const generation = mc.imageGeneration;
      if (generation.kind !== "available") {
        throw new FakeSpaceRefusal(
          "SpaceImageGenerationError",
          generation.kind,
          generation.message,
        );
      }
      return newImage(
        input.spaceId,
        {
          name: `${prompt}.png`,
          mimeType: "image/png",
          sizeBytes: 8,
          prompt,
          generatedBy: input.modelSelection ?? { instanceId: "codex", model: "default" },
        },
        by,
      );
    },
    "space.image.providers": () =>
      mc.imageGeneration.kind === "available"
        ? {
            providers: [
              { instanceId: "codex", driver: "codex", status: "ready", message: null },
              { instanceId: "grok", driver: "grok", status: "ready", message: null },
              {
                instanceId: "claudeAgent",
                driver: "claudeAgent",
                status: "unsupported",
                message: "Claude has no image tool.",
              },
            ],
            selection: { instanceId: "codex", model: "default" },
          }
        : {
            providers: [
              {
                instanceId: "codex",
                driver: "codex",
                status: "unavailable",
                message: "Codex is not set up.",
              },
              {
                instanceId: "claudeAgent",
                driver: "claudeAgent",
                status: "unsupported",
                message: "Claude has no image tool.",
              },
            ],
            selection: null,
          },
    "space.image.trash": (input) => {
      const found = image(input.spaceId, input.imageId);
      if (found.trashedAt !== null) refuse("invalid", `"${found.name}" is already in the trash.`);
      commit(`space:${input.spaceId}`, [["image", found.id, { s: { trashedAt: now() } }]]);
      return { image: table(input.spaceId, "image").get(found.id) };
    },
    "space.image.restore": (input) => {
      const found = image(input.spaceId, input.imageId);
      if (found.trashedAt === null) refuse("invalid", `"${found.name}" is not in the trash.`);
      commit(`space:${input.spaceId}`, [["image", found.id, { s: { trashedAt: null } }]]);
      return { image: table(input.spaceId, "image").get(found.id) };
    },
    // Blocks outlive it: a page says the image was deleted.
    "space.image.delete": (input) => {
      const found = image(input.spaceId, input.imageId);
      if (found.trashedAt === null) {
        refuse("invalid", `Only an image in the trash can be deleted; "${found.name}" is not.`);
      }
      commit(`space:${input.spaceId}`, [["image", found.id, { d: true }]]);
      return { imageId: found.id };
    },
    "space.comment.resolve": (input) => resolve(input, now()),
    "space.comment.reopen": (input) => resolve(input, null),
  };

  const resolve = (input: Entity, resolvedAt: string | null) => {
    const found =
      table(input.spaceId, "comment").get(input.commentId) ??
      refuse("not_found", `There is no comment ${input.commentId} in this Space.`);
    commit(`space:${input.spaceId}`, [
      ["comment", found.id, { s: { resolvedAt, updatedAt: now() } }],
    ]);
    return { comment: table(input.spaceId, "comment").get(found.id) };
  };

  const all = (kind: string) =>
    [...content.values()].flatMap((kinds) => [...kinds.get(kind)!.values()]);
  const named = (kind: string, field: string, value: string) => {
    const found = all(kind).find((entry) => entry[field] === value);
    if (!found) throw new Error(`no ${kind} "${value}" on the fake MC`);
    return found;
  };

  const mc: FakeSpaceMc = {
    attach: (settings) => {
      for (const method of Object.keys(methods)) {
        // The MC's replies are JSON: a client never holds the MC's own objects.
        settings.on(method, (payload) => {
          try {
            return structuredClone(mc.run(method, payload));
          } catch (error) {
            if (error instanceof FakeSpaceRefusal) mc.refusals.push(error.message);
            throw error;
          }
        });
      }
      settings.on("upload", (payload) => {
        const { relativeUrl, bytes } = payload as { relativeUrl: string; bytes: Uint8Array };
        const upload = uploads.get(relativeUrl.split("/").at(-1)!);
        if (upload) upload.bytes = bytes;
      });
      settings.streams = (stream, onFrame) => {
        const watcher: Watcher = { onFrame };
        let set = watchers.get(stream);
        if (!set) watchers.set(stream, (set = new Set()));
        set.add(watcher);
        onFrame(snapshot(stream));
        onFrame({ type: "live" });
        return () => {
          set.delete(watcher);
        };
      };
      settings.presence = (pageId, onViewers) => {
        let clients = pageClients.get(pageId);
        if (!clients) pageClients.set(pageId, (clients = new Set()));
        clients.add(onViewers);
        onViewers(viewersOf(pageId));
        return () => {
          clients.delete(onViewers);
        };
      };
    },
    run: (method, payload, author = user) => {
      const handler = methods[method];
      if (!handler) throw new Error("unsupported");
      return handler(payload, author);
    },
    spaceNamed: (value) => {
      const found = [...spaces.values()].find((entry) => entry.name === value);
      if (!found) throw new Error(`no Space "${value}" on the fake MC`);
      return found;
    },
    pageNamed: (title) => named("page", "title", title),
    blockNamed: (text) => named("block", "text", text),
    commentNamed: (body) => named("comment", "body", body),
    imageNamed: (value) => named("image", "name", value),
    imagesOf: (spaceId) => [...table(spaceId, "image").values()],
    seedImage: (spaceId, value) =>
      newImage(spaceId, { name: value, mimeType: "image/png", sizeBytes: 8 }, user).image,
    spaces: () => [...spaces.values()],
    pagesOf: (spaceId) => pages(spaceId),
    blocksOf: (pageId) => {
      const entry = all("page").find((candidate) => candidate.id === pageId);
      return entry ? blocksOf(entry.spaceId, pageId) : [];
    },
    commentsOf: (pageId) => all("comment").filter((entry) => entry.pageId === pageId),
    generation: { kind: "unavailable", message: "No text generation provider is set up." },
    imageGeneration: { kind: "unavailable", message: "No image generation provider is set up." },
    summaries: [],
    refusals: [],
    siteAddress: "http://192.168.1.20:3773",
    tailnetName: null,
    siteOpens: (url) => all("site").some((site) => site.url === url),
    siteOf: (title) => {
      const found = named("page", "title", title);
      return all("site").find((site) => site.pageId === found.id);
    },
    lastChanges: [],
    restart: () => {
      for (const [stream, set] of watchers) {
        for (const watcher of set) {
          watcher.onFrame(snapshot(stream));
          watcher.onFrame({ type: "live" });
        }
      }
    },
    deviceOn: (pageId, device) => on(devicesOn, pageId, device),
    deviceGone: (device) => gone(devicesOn, device),
    retellViewers: () => {
      for (const pageId of pageClients.keys()) tellPage(pageId);
    },
    agentOn: (pageId, title) => on(agentsOn, pageId, title),
    agentGone: (title) => gone(agentsOn, title),
    clientsOn: (pageId) => pageClients.get(pageId)?.size ?? 0,
  };
  return mc;
}
