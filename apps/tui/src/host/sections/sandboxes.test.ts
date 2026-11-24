import { describe, expect, it } from "bun:test";

import type { OpenShellOperationState } from "@hal-c2/contracts";

import { fakeClient } from "../../../features/support/fakeClient.ts";
import { createHost } from "../host.ts";
import type { TuiSettingsSectionState } from "../settingsSections.ts";

const STOPS = "1 of this MC's review sandboxes is on the gateway.";

// An MC with a gateway it runs and one of its reviews on it. A run starts the
// operation and answers at once; its frames wait for `emit`, so a test can press
// again before the first one lands. A second run while one runs is refused as busy.
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
  mc.on("server.runOpenShellOperation", (payload: { operation: "uninstall" }) => {
    if (state.running) {
      throw new Error(
        "OpenShell's uninstall is already running on this MC. Try uninstall again once it finishes.",
      );
    }
    state = { operation: payload.operation, running: true, steps: [], result: null };
    return state;
  });
  const emit = (next: OpenShellOperationState) => {
    state = next;
    mc.openShellOperation = next;
    mc.emitOpenShellOperation();
  };
  const host = createHost({ client: fake.client, size: { columns: 120, rows: 40 }, log: () => {} });
  const page = () => host.state.get("settingsSection") as TuiSettingsSectionState;
  return { fake, mc, host, page, emit, state: () => state };
}

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
        result: { ok: false, code: "sandboxes-running", message: STOPS, sandboxes: 1 },
      });
      await host.settled();
      expect(host.state.get("mode")).toBe("sectionConfirm");
      expect(page().confirm?.lines.join(" ")).toContain("Stop 1 review and go ahead?");
      expect(page().lines.join("\n")).not.toContain("already running");
      host.destroy();
    });
  }
});
