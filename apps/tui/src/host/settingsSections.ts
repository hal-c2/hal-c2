import type { TuiClient } from "../connection.ts";
import { clip } from "../format.ts";
import type { StatusKind, Store } from "../store.ts";
import { THEME } from "../theme.ts";
import type { TuiMode } from "./layoutState.ts";
import type { PaletteCommand } from "./paletteState.ts";
import { chunk, styled, type StyledText } from "./styledText.ts";

// The settings pages the terminal can change (scheduled tasks, diagnostics,
// storage, …). Each page is a list of rows in the conversation's place: ↑/↓
// move, Enter runs the row (opens it, toggles it, or asks for its value in a
// one-line field), Esc goes back. A page that must ask first (a force kill, a
// removal) shows the question under its rows and takes y / n. The read-only
// overview with the keybinding reference stays `settingsState.ts`.
//
// A section (`sections/*.ts`) says what its page holds (`page()`); this file
// owns the selection, the window of rows that fits, the field, the question
// and what is published under `settingsSection`.

export type SectionTone = "text" | "dim" | "accent" | "error" | "warning" | "success";

/** One line of a page, as a section describes it. */
export type SectionItem =
  | { readonly kind: "heading"; readonly text: string }
  /** Words for the user: wrapped to the pane, never selected. */
  | { readonly kind: "note"; readonly text: string; readonly tone?: SectionTone }
  | { readonly kind: "blank" }
  | {
      readonly kind: "row";
      /** Stable within the page: the selection follows it when the page is rebuilt. */
      readonly id: string;
      readonly label: string;
      readonly value?: string;
      readonly tone?: SectionTone;
      /** Cut a long value to the row instead of carrying it onto the next lines. */
      readonly clip?: boolean;
      /** What Enter does; a row without it is selectable but inert (a listing). */
      readonly run?: () => void;
    };

export interface SectionPage {
  readonly title: string;
  readonly items: ReadonlyArray<SectionItem>;
}

/** What a section may ask of the page it is shown in. */
export interface SectionHost {
  readonly client: TuiClient;
  /** Rebuild the page from `page()` (after data arrived or the user changed something). */
  readonly refresh: () => void;
  /** Ask for one line of text; `submit` gets it trimmed. */
  readonly ask: (
    field: { readonly label: string; readonly value?: string; readonly placeholder?: string },
    submit: (text: string) => void,
  ) => void;
  /** Ask a yes / no question before doing something that cannot be undone. */
  readonly confirm: (question: string, yes: () => void, no?: () => void) => void;
  /** Keep `settled()` waiting on a call this section started. */
  readonly track: <T>(promise: Promise<T>) => Promise<T>;
  /** The status row's message. */
  readonly status: (text: string, kind?: StatusKind) => void;
  readonly isOpen: () => boolean;
  /** Move the selection to a row (a page that opened on something new). */
  readonly select: (rowId: string) => void;
  readonly copyToClipboard: (text: string) => boolean;
  readonly now: () => number;
  readonly store: Store;
}

export interface SettingsSection {
  readonly id: string;
  /** The palette entries that open this section (none: opened from another page). */
  readonly commands?: () => ReadonlyArray<PaletteCommand>;
  readonly open: (payload: unknown) => void;
  readonly close?: () => void;
  readonly page: () => SectionPage;
  /** Esc: true when the section stepped back within itself (an editor closed). */
  readonly back?: () => boolean;
  /** The section's own actions (`scheduledTasks.save`, …); false when it is not one. */
  readonly dispatch?: (action: string, payload: unknown) => boolean;
}

/** A painted row of the page in view. */
export interface TuiSectionRow {
  readonly id: string;
  readonly selectable: boolean;
  readonly selected: boolean;
  readonly text: string;
  readonly line: StyledText;
}

/** Published under `settingsSection`. */
export interface TuiSettingsSectionState {
  readonly open: boolean;
  readonly id: string | null;
  readonly title: string;
  readonly hint: string;
  /** The window of rows that fits the pane, around the selection. */
  readonly rows: ReadonlyArray<TuiSectionRow>;
  /** Every line of the page as plain text, in order (plugins and tests read it). */
  readonly lines: ReadonlyArray<string>;
  readonly selectedId: string | null;
  /** The one-line field (mode "sectionInput"); `seq` changes each time it opens. */
  readonly input: {
    readonly label: string;
    readonly value: string;
    readonly placeholder: string;
    readonly seq: number;
  } | null;
  /** The question (mode "sectionConfirm"), wrapped to the pane. */
  readonly confirm: { readonly lines: ReadonlyArray<string>; readonly hint: string } | null;
}

export const NO_SETTINGS_SECTION: TuiSettingsSectionState = {
  open: false,
  id: null,
  title: "",
  hint: "",
  rows: [],
  lines: [],
  selectedId: null,
  input: null,
  confirm: null,
};

const HINT = "↑/↓ move · Enter choose · Esc back";
const LABEL_COLUMN = 20;

const toneColor = (tone: SectionTone | undefined) =>
  tone === undefined || tone === "text" ? THEME.text : THEME[tone];

/** Break `text` into lines of at most `width` cells at spaces (a long word is cut). */
export function wrapWords(text: string, width: number): string[] {
  const size = Math.max(8, width);
  const lines: string[] = [];
  for (const paragraph of text.split("\n")) {
    let line = "";
    for (const word of paragraph.split(/\s+/).filter(Boolean)) {
      let rest = word;
      while (Bun.stringWidth(rest) > size) {
        if (line !== "") lines.push(line);
        line = "";
        lines.push(rest.slice(0, size));
        rest = rest.slice(size);
      }
      if (line === "") line = rest;
      else if (Bun.stringWidth(line) + 1 + Bun.stringWidth(rest) <= size) line += ` ${rest}`;
      else {
        lines.push(line);
        line = rest;
      }
    }
    lines.push(line);
  }
  return lines;
}

interface Painted {
  readonly id: string;
  readonly selectable: boolean;
  readonly text: string;
  readonly paint: (selected: boolean) => StyledText;
  readonly run?: (() => void) | undefined;
}

function paint(items: ReadonlyArray<SectionItem>, width: number): Painted[] {
  const painted: Painted[] = [];
  items.forEach((item, index) => {
    if (item.kind === "blank") {
      painted.push({ id: `blank-${index}`, selectable: false, text: "", paint: () => styled() });
    } else if (item.kind === "heading") {
      const line = styled(chunk(clip(item.text, width), { fg: THEME.accent }));
      painted.push({
        id: `heading-${index}`,
        selectable: false,
        text: item.text,
        paint: () => line,
      });
    } else if (item.kind === "note") {
      wrapWords(item.text, width - 2).forEach((text, part) => {
        const line = styled(chunk(`  ${text}`, { fg: toneColor(item.tone ?? "dim") }));
        painted.push({
          id: `note-${index}-${part}`,
          selectable: false,
          text: `  ${text}`,
          paint: () => line,
        });
      });
    } else {
      const value = item.value ?? "";
      const label = value === "" ? item.label : item.label.padEnd(LABEL_COLUMN);
      const labelText = clip(label, width - 2);
      const valueWidth = width - 3 - Bun.stringWidth(labelText);
      // A value too long for its column goes on under itself; a clipped one is cut.
      const values =
        value === "" || valueWidth < 8
          ? []
          : item.clip === true
            ? [clip(value, valueWidth)]
            : wrapWords(value, valueWidth);
      const first = values[0] ?? "";
      painted.push({
        id: item.id,
        selectable: true,
        text: `  ${labelText}${first === "" ? "" : ` ${first}`}`,
        run: item.run,
        paint: (selected) =>
          styled(
            chunk(selected ? "▸ " : "  ", { fg: THEME.accent }),
            chunk(labelText, { fg: selected ? THEME.accent : THEME.text }),
            first === "" ? null : chunk(` ${first}`, { fg: toneColor(item.tone ?? "dim") }),
          ),
      });
      const indent = " ".repeat(3 + Bun.stringWidth(labelText));
      values.slice(1).forEach((text, part) => {
        const line = styled(chunk(`${indent}${text}`, { fg: toneColor(item.tone ?? "dim") }));
        painted.push({
          id: `${item.id}~${part}`,
          selectable: false,
          text: `${indent}${text}`,
          paint: () => line,
        });
      });
    }
  });
  return painted;
}

export function createSettingsSections(ctx: {
  readonly client: TuiClient;
  readonly store: Store;
  readonly mode: () => TuiMode;
  readonly setMode: (mode: TuiMode) => void;
  readonly restingMode: () => TuiMode;
  /** The conversation pane's size: the page fills it. */
  readonly pane: () => { readonly width: number; readonly rows: number };
  readonly copyToClipboard: ((text: string) => boolean) | undefined;
  readonly now: () => number;
  readonly publish: (state: TuiSettingsSectionState) => void;
  /** A page opened or closed: the layout hides the detail panel under it. */
  readonly openChanged: () => void;
}) {
  const sections = new Map<string, SettingsSection>();
  const pending = new Set<Promise<unknown>>();
  let current: SettingsSection | null = null;
  let selectedId: string | null = null;
  let field: {
    label: string;
    value: string;
    placeholder: string;
    seq: number;
    submit: (text: string) => void;
  } | null = null;
  let question: { text: string; yes: () => void; no: (() => void) | undefined } | null = null;
  let inputSeq = 0;
  let painted: Painted[] = [];

  const track = <T>(promise: Promise<T>): Promise<T> => {
    pending.add(promise);
    const done = () => pending.delete(promise);
    promise.then(done, done);
    return promise;
  };

  const syncMode = () => {
    if (!current) return;
    ctx.setMode(question ? "sectionConfirm" : field ? "sectionInput" : "section");
  };

  const publish = () => {
    if (!current) {
      ctx.publish(NO_SETTINGS_SECTION);
      return;
    }
    const pane = ctx.pane();
    // Inside the border and its padding.
    const width = Math.max(12, pane.width - 4);
    const page = current.page();
    painted = paint(page.items, width);
    const selectable = painted.filter((row) => row.selectable);
    if (!selectable.some((row) => row.id === selectedId)) {
      selectedId = selectable[0]?.id ?? null;
    }
    const confirmLines = question ? wrapWords(question.text, width) : [];
    const chrome = 3 + (field ? 2 : 0) + (question ? confirmLines.length + 1 : 0);
    const capacity = Math.max(1, pane.rows - chrome);
    const at = Math.max(
      0,
      painted.findIndex((row) => row.id === selectedId),
    );
    // Keep the selection in view, with the lines above it (its heading) when they fit.
    const start = Math.max(0, Math.min(at - Math.floor(capacity / 2), painted.length - capacity));
    ctx.publish({
      open: true,
      id: current.id,
      title: page.title,
      hint: HINT,
      rows: painted.slice(start, start + capacity).map((row) => ({
        id: row.id,
        selectable: row.selectable,
        selected: row.id === selectedId,
        text: row.text,
        line: row.paint(row.id === selectedId),
      })),
      lines: painted.map((row) => row.text),
      selectedId,
      input: field
        ? {
            label: field.label,
            value: field.value,
            placeholder: field.placeholder,
            seq: field.seq,
          }
        : null,
      confirm: question ? { lines: confirmLines, hint: "y yes · n / Esc no" } : null,
    });
  };

  const hostFor = (id: string): SectionHost => ({
    client: ctx.client,
    store: ctx.store,
    refresh: () => {
      if (current?.id === id) publish();
    },
    ask: (input, submit) => {
      if (current?.id !== id) return;
      field = {
        label: input.label,
        value: input.value ?? "",
        placeholder: input.placeholder ?? "",
        seq: ++inputSeq,
        submit,
      };
      syncMode();
      publish();
    },
    confirm: (text, yes, no) => {
      if (current?.id !== id) return;
      question = { text, yes, no };
      syncMode();
      publish();
    },
    track,
    status: (text, kind) => ctx.store.setStatus(text, kind),
    isOpen: () => current?.id === id,
    select: (rowId) => {
      selectedId = rowId;
      if (current?.id === id) publish();
    },
    copyToClipboard: (text) => ctx.copyToClipboard?.(text) === true,
    now: ctx.now,
  });

  const close = () => {
    if (!current) return;
    const closing = current;
    current = null;
    field = null;
    question = null;
    selectedId = null;
    closing.close?.();
    publish();
    ctx.openChanged();
    const mode = ctx.mode();
    if (mode === "section" || mode === "sectionInput" || mode === "sectionConfirm") {
      ctx.setMode(ctx.restingMode());
    }
  };

  const open = (id: string, payload: unknown) => {
    const section = sections.get(id);
    if (!section) return false;
    if (current && current !== section) close();
    const opening = current !== section;
    current = section;
    field = null;
    question = null;
    if (opening) selectedId = null;
    section.open(payload);
    publish();
    if (opening) ctx.openChanged();
    syncMode();
    return true;
  };

  const move = (delta: number) => {
    const selectable = painted.filter((row) => row.selectable);
    if (selectable.length === 0) return;
    const at = selectable.findIndex((row) => row.id === selectedId);
    const next = Math.max(0, Math.min(selectable.length - 1, at + delta));
    selectedId = selectable[next]!.id;
    publish();
  };

  const field$ = (payload: unknown, name: string): unknown =>
    typeof payload === "object" && payload !== null
      ? (payload as Record<string, unknown>)[name]
      : undefined;

  return {
    /** Add a section; `build` gets what it may ask of its page. */
    register: (id: string, build: (host: SectionHost) => SettingsSection) => {
      sections.set(id, build(hostFor(id)));
    },
    isOpen: () => current !== null,
    close,
    /** The pane was resized: rows are painted to its width and windowed to its height. */
    relayout: () => {
      if (current) publish();
    },
    commands: (): PaletteCommand[] =>
      [...sections.values()].flatMap((section) => [...(section.commands?.() ?? [])]),
    /** Resolves once every call a section started has landed (tests wait on it). */
    settled: async () => {
      while (pending.size > 0) await Promise.allSettled(pending);
    },
    dispatch: (action: string, payload: unknown): boolean => {
      switch (action) {
        case "section.open": {
          const id = field$(payload, "id");
          return typeof id === "string" ? open(id, payload) : true;
        }
        case "section.close":
          close();
          return true;
        case "section.back":
          if (current && current.back?.() !== true) close();
          else if (current) publish();
          return true;
        case "section.previous":
          move(-1);
          return true;
        case "section.next":
          move(1);
          return true;
        case "section.activate": {
          const id = field$(payload, "id");
          if (typeof id === "string") selectedId = id;
          const row = painted.find((candidate) => candidate.id === selectedId);
          if (typeof id === "string") publish();
          row?.run?.();
          return true;
        }
        case "section.input.submit": {
          const asked = field;
          if (!asked) return true;
          field = null;
          syncMode();
          const text = field$(payload, "text");
          asked.submit(typeof text === "string" ? text.trim() : "");
          publish();
          return true;
        }
        case "section.input.cancel":
          field = null;
          syncMode();
          publish();
          return true;
        case "section.confirm.yes":
        case "section.confirm.no": {
          const asked = question;
          if (!asked) return true;
          question = null;
          syncMode();
          if (action === "section.confirm.yes") asked.yes();
          else asked.no?.();
          publish();
          return true;
        }
        default:
          for (const section of sections.values()) {
            if (section.dispatch?.(action, payload) === true) return true;
          }
          return false;
      }
    },
  };
}

export type SettingsSections = ReturnType<typeof createSettingsSections>;
