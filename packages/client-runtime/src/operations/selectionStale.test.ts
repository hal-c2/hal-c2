import { describe, expect, it } from "vite-plus/test";

import { selectionStaleRefusal } from "./selectionStale.ts";

describe("selectionStaleRefusal", () => {
  it("reads the MC's detail through the command error's cause", () => {
    const rpc = Object.assign(new Error("The thread's selection moved"), {
      detail: {
        code: "selection-stale",
        selectionRevision: 7,
        modelSelection: { instanceId: "claudeAgent", model: "claude-opus-5-5" },
      },
    });
    const failure = {
      _tag: "OrchestrationV2DispatchCommandError",
      message: rpc.message,
      cause: rpc,
    };

    expect(selectionStaleRefusal(failure)).toEqual({
      selectionRevision: 7,
      modelSelection: { instanceId: "claudeAgent", model: "claude-opus-5-5" },
    });
  });

  it("names nothing it was not sent and ignores other refusals", () => {
    expect(selectionStaleRefusal({ cause: { detail: { code: "selection-stale" } } })).toEqual({
      selectionRevision: null,
      modelSelection: null,
    });
    expect(selectionStaleRefusal(new Error("selection-stale"))).toBeNull();
    expect(selectionStaleRefusal({ detail: { code: "thread-moving" } })).toBeNull();
  });
});
