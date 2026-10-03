import {
  COMPOSER_CONTEXT_REVIEW_DIFF_MAX_CHARS,
  COMPOSER_CONTEXT_REVIEW_TEXT_MAX_CHARS,
  COMPOSER_CONTEXT_TERMINAL_TEXT_MAX_CHARS,
  type KnownComposerContextRecord,
} from "@hal-c2/contracts";

import { clip } from "../../format.ts";
import type { Feature, FeatureKit } from "./kit.ts";

/** The most terminal lines one chip carries; a longer pick keeps its newest lines. */
export const TERMINAL_CONTEXT_MAX_LINES = 200;

let contextSeq = 0;
const contextId = (kind: string) =>
  `tui-${kind}-${Date.now().toString(36)}-${(contextSeq += 1).toString(36)}` as never;

interface DiffLine {
  readonly path: string;
  /** The line's place in the file's diff body. */
  readonly index: number;
  readonly text: string;
  /** Its line number in the file: the new side's, or the old side's for a removed line. */
  readonly number: number;
}

/** The added and removed lines of each file shown in the diff viewer, numbered by their hunks. */
function changedLines(files: ReadonlyArray<{ path: string; body: string }>): DiffLine[] {
  const lines: DiffLine[] = [];
  for (const file of files) {
    let oldLine = 0;
    let newLine = 0;
    file.body.split("\n").forEach((text, index) => {
      const hunk = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(text);
      if (hunk) {
        oldLine = Number(hunk[1]);
        newLine = Number(hunk[2]);
      } else if (/^\+(?!\+\+ )/.test(text)) {
        lines.push({ path: file.path, index, text, number: newLine });
        newLine += 1;
      } else if (/^-(?!-- )/.test(text)) {
        lines.push({ path: file.path, index, text, number: oldLine });
        oldLine += 1;
      } else if (text.startsWith(" ")) {
        oldLine += 1;
        newLine += 1;
      }
    });
  }
  return lines;
}

/**
 * Context for the next prompt, picked outside it: terminal output, and a note
 * on a line of the open diff. Each becomes a chip on the prompt and a typed
 * record on the message (`packages/contracts/src/composerContext.ts`); the
 * prompt's text names it with a reference link when it is sent.
 */
export function createContextFeature(kit: FeatureKit): Feature {
  const terminal = () =>
    kit.state.get("terminal") as
      | {
          open: boolean;
          activeId: string | null;
          title: string;
        }
      | undefined;
  const diff = () =>
    kit.state.get("diff") as
      | { open: boolean; title: string; files: ReadonlyArray<{ path: string; body: string }> }
      | undefined;

  const attach = (record: KnownComposerContextRecord, said: string) => {
    if (kit.addContext(record)) kit.status(said, "success");
    else kit.status("Open a thread to attach context to its prompt.", "error");
  };

  /** The screen's lines without the blank rows under the output. */
  const screenLines = () => {
    const lines = (kit.terminalText() ?? "").split("\n").map((line) => line.trimEnd());
    while (lines.length > 0 && lines.at(-1) === "") lines.pop();
    return lines;
  };

  const addTerminal = (lines: ReadonlyArray<string>, from: number) => {
    const current = terminal();
    if (!current?.activeId || lines.length === 0) return;
    // Bounded twice: by lines, then by what a record may hold.
    const kept = lines.slice(-TERMINAL_CONTEXT_MAX_LINES);
    const text = kept.join("\n").slice(-COMPOSER_CONTEXT_TERMINAL_TEXT_MAX_CHARS);
    const start = from + (lines.length - kept.length);
    const count = kept.length;
    attach(
      {
        version: 1,
        contextId: contextId("terminal"),
        kind: "terminal",
        label: `terminal · ${count} line${count === 1 ? "" : "s"}`,
        terminalId: current.activeId as never,
        terminalLabel: (current.title || "terminal") as never,
        lineStart: start as never,
        lineEnd: (start + count - 1) as never,
        text,
      },
      `Added ${count} terminal line${count === 1 ? "" : "s"} to the prompt.`,
    );
  };

  /** What is on the terminal's screen (scroll back to choose it), whole or its last lines. */
  const pickTerminal = () => {
    const lines = screenLines();
    if (!terminal()?.open || lines.length === 0) {
      kit.status("The terminal shows nothing to add.", "info");
      return;
    }
    const choices = [lines.length, 25, 10, 5].filter(
      (count, index, all) => count <= lines.length && all.indexOf(count) === index,
    );
    kit.menu({
      title: "terminal output",
      options: choices.map((count) => ({
        label: count === lines.length ? `The screen (${count} lines)` : `The last ${count} lines`,
        description: clip(lines.at(-count) ?? "", 60),
        value: String(count),
      })),
      onChoose: (value) => {
        const count = Number(value);
        addTerminal(lines.slice(-count), lines.length - count);
      },
    });
  };

  /** A line of the open diff, the line the note runs through, then the note. */
  const noteOnDiff = () => {
    const open = diff();
    const lines = open?.open ? changedLines(open.files) : [];
    if (!open || lines.length === 0) {
      kit.status("Open a diff with changes to note a line.", "info");
      return;
    }
    const askNote = (first: DiffLine, last: DiffLine) => {
      const body = open.files.find((file) => file.path === first.path)?.body.split("\n") ?? [];
      const picked = body.slice(first.index, last.index + 1);
      const sameSide = picked.every((text) => text[0] === first.text[0]) ? first.text[0]! : "";
      const range =
        first.number === last.number ? `L${first.number}` : `L${first.number}-${last.number}`;
      kit.ask({
        label: "note",
        placeholder: `What should change at ${first.path}:${range.slice(1)}?`,
        returnMode: "diff",
        onSubmit: (note) => {
          if (note === "") return;
          attach(
            {
              version: 1,
              contextId: contextId("review"),
              kind: "review-comment",
              label: `${first.path} ${range}`,
              sectionId: open.title as never,
              sectionTitle: open.title,
              filePath: first.path as never,
              startIndex: first.index as never,
              endIndex: last.index as never,
              // As the web words it: the side's marker when every line is on one side.
              rangeLabel:
                first.number === last.number
                  ? `${sameSide}${first.number}`
                  : `${sameSide}${first.number} to ${sameSide}${last.number}`,
              text: note.slice(0, COMPOSER_CONTEXT_REVIEW_TEXT_MAX_CHARS),
              diff: picked.join("\n").slice(0, COMPOSER_CONTEXT_REVIEW_DIFF_MAX_CHARS),
            },
            `Note on ${first.path} ${first.number === last.number ? `line ${first.number}` : `lines ${first.number} to ${last.number}`} added to the prompt.`,
          );
        },
      });
    };
    kit.menu({
      title: "note on",
      searchable: true,
      returnMode: "diff",
      options: lines.map((line, at) => ({
        label: clip(line.text, 100),
        description: `${line.path} · line ${line.number}`,
        value: String(at),
      })),
      onChoose: (value) => {
        const first = lines[Number(value)];
        if (!first) return;
        // The lines after it in the same file: a note may run through several.
        const later = lines.filter((line) => line.path === first.path && line.index > first.index);
        if (later.length === 0) {
          askNote(first, first);
          return;
        }
        kit.menu({
          title: `note from line ${first.number} through`,
          returnMode: "diff",
          options: [
            { label: "Only this line", description: clip(first.text, 60), value: "-1" },
            ...later.map((line, at) => ({
              label: `Line ${line.number}`,
              description: clip(line.text, 60),
              value: String(at),
            })),
          ],
          onChoose: (through) => askNote(first, later[Number(through)] ?? first),
        });
      },
    });
  };

  return {
    commands: () => [
      ...(terminal()?.open
        ? [
            {
              id: "context.terminal",
              title: "Add terminal output to the prompt…",
              keywords: "context selection lines attach",
              action: "context.terminal",
            },
          ]
        : []),
      ...(diff()?.open
        ? [
            {
              id: "context.diffNote",
              title: "Note a diff line for the prompt…",
              hint: "c",
              keywords: "comment annotate review context",
              action: "context.diffNote",
            },
          ]
        : []),
    ],
    dispatch: (action) => {
      if (action === "context.terminal") {
        pickTerminal();
        return true;
      }
      if (action === "context.diffNote") {
        noteOnDiff();
        return true;
      }
      return false;
    },
  };
}
