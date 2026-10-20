import { describe, expect, it } from "bun:test";
import { createPropertyMap } from "opentui-qml";

import type { PickRequest } from "./composerState.ts";
import { STATUS_HISTORY_LIMIT, createStatusLog } from "./statusLog.ts";

function setup() {
  const state = createPropertyMap();
  const cleared: string[] = [];
  const picks: PickRequest[] = [];
  const copied: string[] = [];
  const said: string[] = [];
  const clipboard = { works: true };
  const log = createStatusLog({
    state,
    now: () => "2026-07-14T00:00:00.000Z",
    clearCurrent: (text) => cleared.push(text),
    pick: (request) => picks.push(request),
    copy: (text) => {
      if (clipboard.works) copied.push(text);
      return clipboard.works;
    },
    say: (text) => said.push(text),
  });
  return { state, log, cleared, picks, copied, said, clipboard };
}

const error = (text: string) => ({ kind: "error", text }) as const;

describe("status log", () => {
  it("pins only errors, and a newer error replaces the pinned one", () => {
    const { state, log } = setup();
    log.note({ kind: "info", text: "Ready." });
    expect(state.get("statusError")).toBeNull();
    log.note(error("first"));
    log.note({ kind: "success", text: "Done." });
    expect(state.get("statusError")).toEqual({ text: "first" });
    log.note(error("second"));
    expect(state.get("statusError")).toEqual({ text: "second" });
  });

  it("does not pin a warning, which is a hint about the user's input", () => {
    const { state, log } = setup();
    log.note({ kind: "warning", text: "Enter a whole number of days" });
    expect(state.get("statusError")).toBeNull();
    expect(log.commands().map((command) => command.id)).toEqual([]);
  });

  it("dispatching history or dismiss with nothing logged or pinned opens no picker and clears nothing", () => {
    const { log, picks, cleared } = setup();
    expect(log.dispatch("status.history")).toBe(true);
    expect(log.dispatch("status.dismiss")).toBe(true);
    expect(picks).toEqual([]);
    expect(cleared).toEqual([]);
  });

  it("offers the history only once an error has been logged", () => {
    const { log } = setup();
    const ids = () => log.commands().map((command) => command.id);
    expect(ids()).toEqual([]);
    log.note(error("boom"));
    log.dispatch("status.dismiss");
    expect(ids()).toEqual(["status.history"]);
  });

  it("offers dismissal only while an error is pinned, and clears the line it was on", () => {
    const { log, state, cleared } = setup();
    const ids = () => log.commands().map((command) => command.id);
    expect(ids()).toEqual([]);
    log.note(error("boom"));
    expect(ids()).toEqual(["status.dismiss", "status.history"]);
    expect(log.dispatch("status.dismiss")).toBe(true);
    expect(state.get("statusError")).toBeNull();
    expect(cleared).toEqual(["boom"]);
    expect(ids()).toEqual(["status.history"]);
  });

  it("does not record the same error again while it is pinned", () => {
    const { log, picks } = setup();
    log.note(error("boom"));
    log.note(error("boom"));
    log.dispatch("status.history");
    expect(picks[0]!.options).toHaveLength(1);
  });

  it("lists the errors newest first, keeps the last few, and reading them dismisses the pinned one", () => {
    const { log, picks, state } = setup();
    for (let n = 0; n < STATUS_HISTORY_LIMIT + 5; n += 1) log.note(error(`error ${n}`));
    log.dispatch("status.history");
    const labels = picks[0]!.options.map((option) => option.label);
    expect(labels).toHaveLength(STATUS_HISTORY_LIMIT);
    expect(labels[0]).toBe(`error ${STATUS_HISTORY_LIMIT + 4}`);
    expect(state.get("statusError")).toBeNull();
  });

  it("copies the whole error when the user chooses it from the history", () => {
    const { log, picks, copied, said, clipboard } = setup();
    const long = `Push failed: ${"x".repeat(300)}`;
    log.note(error(long));
    log.note(error("short"));
    log.dispatch("status.history");
    picks[0]!.onChoose("1");
    expect(copied).toEqual([long]);
    expect(said).toEqual(["Error copied to clipboard."]);
    clipboard.works = false;
    picks[0]!.onChoose("0");
    expect(copied).toEqual([long]);
    expect(said.at(-1)).toBe("Clipboard unavailable here.");
  });

  it("copies the entry the picker listed even when a newer error arrived while it was open", () => {
    const { log, picks, copied } = setup();
    log.note(error("older"));
    log.dispatch("status.history");
    log.note(error("newer"));
    picks[0]!.onChoose("0");
    expect(copied).toEqual(["older"]);
  });
});
