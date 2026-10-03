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
}

/** The added and removed lines of each file shown in the diff viewer. */
function changedLines(files: ReadonlyArray<{ path: string; body: string }>): DiffLine[] {
  const lines: DiffLine[] = [];
  for (const file of files) {
    file.body.split("\n").forEach((text, index) => {
      if (/^[+-](?![+-]{2} )/.test(text)) lines.push({ path: file.path, index, text });
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

  /** A line of the open diff, then the note on it. */
  const noteOnDiff = () => {
    const open = diff();
    const lines = open?.open ? changedLines(open.files) : [];
    if (!open || lines.length === 0) {
      kit.status("Open a diff with changes to note a line.", "info");
      return;
    }
    kit.menu({
      title: "note on",
      searchable: true,
      returnMode: "diff",
      options: lines.map((line, at) => ({
        label: clip(line.text, 100),
        description: `${line.path} · line ${line.index + 1}`,
        value: String(at),
      })),
      onChoose: (value) => {
        const line = lines[Number(value)];
        if (!line) return;
        kit.ask({
          label: "note",
          placeholder: `What should change at ${line.path}:${line.index + 1}?`,
          returnMode: "diff",
          onSubmit: (note) => {
            if (note === "") return;
            attach(
              {
                version: 1,
                contextId: contextId("review"),
                kind: "review-comment",
                label: `${line.path} L${line.index + 1}`,
                sectionId: open.title as never,
                sectionTitle: open.title,
                filePath: line.path as never,
                startIndex: line.index as never,
                endIndex: line.index as never,
                rangeLabel: `L${line.index + 1}`,
                text: note.slice(0, COMPOSER_CONTEXT_REVIEW_TEXT_MAX_CHARS),
                diff: line.text.slice(0, COMPOSER_CONTEXT_REVIEW_DIFF_MAX_CHARS),
              },
              `Note on ${line.path} line ${line.index + 1} added to the prompt.`,
            );
          },
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
