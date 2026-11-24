import { describe, expect, it } from "bun:test";

import type { OpenShellOperationState } from "@hal-c2/contracts";

import { fakeClient } from "../../../features/support/fakeClient.ts";
import { createHost } from "../host.ts";
import type { TuiSettingsSectionState } from "../settingsSections.ts";

const STOPS = "1 of this MC's review sandboxes is on the gateway.";

// An MC with a gateway it runs and one of its reviews on it. A run starts the
// operation, numbered, and answers at once; its frames wait for `emit`, so a test
// can press again before the first one lands. A second run while one runs is
// refused as busy.
function boot() {
  const fake = fakeClient();
  const mc = fake.settings;
  mc.on("server.getOpenShellStatus", () => ({
    supported: true,
    ready: true,
    mode: "managed",
    version: "0.1.7",
    pinnedVersion: "0.1.7",
    problems: [],
    actions: [{ operation: "uninstall", label: "Uninstall" }],
    canManage: true,
    manageReason: null,
  }));
  let state: OpenShellOperationState = mc.openShellOperation;
  const start = (payload: { operation: "uninstall" }) => {
    if (state.running) {
      throw new Error(
        "OpenShell's uninstall is already running on this MC. Try uninstall again once it finishes.",
      );
    }
    state = {
      operation: payload.operation,
      run: state.run + 1,
      running: true,
      steps: [],
      result: null,
    };
    return state;
  };
  mc.on("server.runOpenShellOperation", start);
  const emit = (next: OpenShellOperationState) => {
    state = next;
    mc.openShellOperation = next;
    mc.emitOpenShellOperation();
  };
  const host = createHost({ client: fake.client, size: { columns: 120, rows: 40 }, log: () => {} });
  const page = () => host.state.get("settingsSection") as TuiSettingsSectionState;
  return { fake, mc, host, page, emit, start, state: () => state };
}

// Every reply and frame already sent lands; for a test holding a reply back,
// which `settled()` would wait on.
const landed = () => new Promise<void>((resolve) => setImmediate(resolve));

describe("review sandboxes", () => {
  for (const when of ["at once", "after the first run's reply"] as const) {
    it(`a second press ${when}, before the first frame, runs nothing and keeps the question`, async () => {
      const { fake, mc, host, page, emit, state } = boot();
      fake.connect();
      host.dispatch("section.open", { id: "sandboxes" });
      await host.settled();
      expect(page().lines.join("\n")).toContain("Uninstall");

      host.dispatch("section.activate", { id: "operation:uninstall" });
      if (when !== "at once") await host.settled();
      host.dispatch("section.activate", { id: "operation:uninstall" });
      await host.settled();
      expect(mc.callsTo("server.runOpenShellOperation")).toHaveLength(1);

      emit(state());
      emit({
        ...state(),
        running: false,
        result: {
          ok: false,
          code: "sandboxes-running",
          message: STOPS,
          sandboxes: 1,
          drain: ["review-1"],
        },
      });
      await host.settled();
      expect(host.state.get("mode")).toBe("sectionConfirm");
      expect(page().confirm?.lines.join(" ")).toContain("Stop 1 review and go ahead?");
      expect(page().lines.join("\n")).not.toContain("already running");
      host.destroy();
    });
  }

  it("a frame from before the run keeps the actions off and asks nothing", async () => {
    const { fake, mc, host, page, emit, state } = boot();
    fake.connect();
    host.dispatch("section.open", { id: "sandboxes" });
    await host.settled();

    host.dispatch("section.activate", { id: "operation:uninstall" });
    await host.settled();
    // Another device's last uninstall, sent before this run started, lands first.
    mc.openShellOperation = {
      operation: "uninstall",
      run: 0,
      running: false,
      steps: [],
      result: {
        ok: false,
        code: "sandboxes-running",
        message: STOPS,
        sandboxes: 1,
        drain: ["review-1"],
      },
    };
    mc.emitOpenShellOperation();
    await host.settled();
    expect(host.state.get("mode")).not.toBe("sectionConfirm");
    host.dispatch("section.activate", { id: "operation:uninstall" });
    await host.settled();
    expect(mc.callsTo("server.runOpenShellOperation")).toHaveLength(1);

    emit(state());
    emit({
      ...state(),
      running: false,
      result: {
        ok: false,
        code: "sandboxes-running",
        message: STOPS,
        sandboxes: 1,
        drain: ["review-1"],
      },
    });
    await host.settled();
    expect(host.state.get("mode")).toBe("sectionConfirm");
    expect(page().lines.join("\n")).not.toContain("already running");
    host.destroy();
  });

  it("a run that ended while the connection was down settles on the first frame after it", async () => {
    const { fake, mc, host, page, emit, state } = boot();
    fake.connect();
    host.dispatch("section.open", { id: "sandboxes" });
    await host.settled();

    host.dispatch("section.activate", { id: "operation:uninstall" });
    await host.settled();
    expect(mc.callsTo("server.runOpenShellOperation")).toHaveLength(1);
    // The connection drops before the running frame, and the run ends before the
    // shape is followed again: its first frame then is the run, ended.
    emit({
      ...state(),
      running: false,
      result: {
        ok: false,
        code: "sandboxes-running",
        message: STOPS,
        sandboxes: 1,
        drain: ["review-1"],
      },
    });
    await host.settled();
    expect(host.state.get("mode")).toBe("sectionConfirm");
    expect(page().confirm?.lines.join(" ")).toContain("Stop 1 review and go ahead?");
    expect(mc.callsTo("server.getOpenShellStatus")).toHaveLength(2);
    host.destroy();
  });

  it("a refusal from before the page closed leaves the press after it reopened alone", async () => {
    const { fake, mc, host, page, emit, start, state } = boot();
    fake.connect();
    host.dispatch("section.open", { id: "sandboxes" });
    await host.settled();

    let refuse: (cause: Error) => void = () => {};
    mc.on(
      "server.runOpenShellOperation",
      () =>
        new Promise((_resolve, reject) => {
          refuse = reject;
        }),
    );
    host.dispatch("section.activate", { id: "operation:uninstall" });
    host.dispatch("section.close");
    mc.on("server.runOpenShellOperation", start);
    host.dispatch("section.open", { id: "sandboxes" });
    await landed();
    host.dispatch("section.activate", { id: "operation:uninstall" });
    await landed();
    expect(mc.callsTo("server.runOpenShellOperation")).toHaveLength(2);

    // The first press's refusal lands now, after the second press started.
    refuse(new Error("OpenShell's status did not answer in time."));
    await host.settled();
    expect(page().lines.join("\n")).not.toContain("did not answer in time");

    emit(state());
    emit({
      ...state(),
      running: false,
      result: {
        ok: false,
        code: "sandboxes-running",
        message: STOPS,
        sandboxes: 1,
        drain: ["review-1"],
      },
    });
    await host.settled();
    expect(host.state.get("mode")).toBe("sectionConfirm");
    expect(page().confirm?.lines.join(" ")).toContain("Stop 1 review and go ahead?");
    host.destroy();
  });

  for (const when of [
    "before its first frame",
    "while it runs",
    "while it runs, its clock stepped back",
  ] as const) {
    it(`an MC that restarted ${when} settles the run as lost`, async () => {
      const { fake, mc, host, page, emit, state } = boot();
      fake.connect();
      host.dispatch("section.open", { id: "sandboxes" });
      await host.settled();

      host.dispatch("section.activate", { id: "operation:uninstall" });
      await host.settled();
      if (when !== "before its first frame") {
        emit(state());
      } else {
        // A frame from before the run, with no operation, neither reopens the
        // actions nor says the MC restarted.
        mc.openShellOperation = {
          operation: null,
          run: 0,
          running: false,
          steps: [],
          result: null,
        };
        mc.emitOpenShellOperation();
        await host.settled();
        expect(page().lines.join("\n")).not.toContain("restarted");
      }
      host.dispatch("section.activate", { id: "operation:uninstall" });
      await host.settled();
      expect(mc.callsTo("server.runOpenShellOperation")).toHaveLength(1);

      // The restarted MC has run nothing, numbered when it started: after the run,
      // or below the last frame's for a clock stepped back.
      const run =
        when === "while it runs, its clock stepped back" ? state().run - 1 : state().run + 1_000;
      emit({ operation: null, run, running: false, steps: [], result: null });
      await host.settled();
      expect(page().lines.join("\n")).toContain(
        "The MC lost track of the run; check the status before trying again.",
      );
      expect(mc.callsTo("server.getOpenShellStatus")).toHaveLength(2);
      host.dispatch("section.activate", { id: "operation:uninstall" });
      await host.settled();
      expect(mc.callsTo("server.runOpenShellOperation")).toHaveLength(2);
      host.destroy();
    });
  }

  it("a yes names the reviews it asked about, and asks again when they changed", async () => {
    const { fake, mc, host, page, emit, state } = boot();
    fake.connect();
    host.dispatch("section.open", { id: "sandboxes" });
    await host.settled();

    host.dispatch("section.activate", { id: "operation:uninstall" });
    await host.settled();
    emit({
      ...state(),
      running: false,
      result: {
        ok: false,
        code: "sandboxes-running",
        message: STOPS,
        sandboxes: 1,
        drain: ["review-1"],
      },
    });
    await host.settled();
    host.dispatch("section.confirm.yes");
    await host.settled();
    expect(mc.callsTo("server.runOpenShellOperation").at(-1)?.payload).toEqual({
      operation: "uninstall",
      drain: ["review-1"],
    });

    // Another review started before the yes: the MC deleted nothing and names both.
    emit({
      ...state(),
      running: false,
      result: {
        ok: false,
        code: "sandboxes-changed",
        message: "The running reviews changed since you confirmed.",
        sandboxes: 2,
        drain: ["review-1", "review-2"],
      },
    });
    await host.settled();
    expect(host.state.get("mode")).toBe("sectionConfirm");
    expect(page().confirm?.lines.join(" ")).toContain("Stop 2 reviews and go ahead?");
    host.dispatch("section.confirm.yes");
    await host.settled();
    expect(mc.callsTo("server.runOpenShellOperation").at(-1)?.payload).toEqual({
      operation: "uninstall",
      drain: ["review-1", "review-2"],
    });
    host.destroy();
  });

  it("a run another device ended while the connection was down reads the status again, once", async () => {
    const { fake, mc, host, emit } = boot();
    // The page opens on a run that ended: the read it opens with covers it.
    mc.openShellOperation = {
      operation: "uninstall",
      run: 5,
      running: false,
      steps: [],
      result: { ok: true, code: null, message: "OpenShell removed.", sandboxes: null, drain: null },
    };
    fake.connect();
    host.dispatch("section.open", { id: "sandboxes" });
    await host.settled();
    mc.emitOpenShellOperation();
    await host.settled();
    expect(mc.callsTo("server.getOpenShellStatus")).toHaveLength(1);

    // The first frame after reconnecting: another device installed meanwhile.
    const installed: OpenShellOperationState = {
      operation: "install",
      run: 6,
      running: false,
      steps: [],
      result: {
        ok: true,
        code: null,
        message: "OpenShell installed.",
        sandboxes: null,
        drain: null,
      },
    };
    emit(installed);
    await host.settled();
    expect(mc.callsTo("server.getOpenShellStatus")).toHaveLength(2);
    emit(installed);
    await host.settled();
    expect(mc.callsTo("server.getOpenShellStatus")).toHaveLength(2);
    host.destroy();
  });
});
