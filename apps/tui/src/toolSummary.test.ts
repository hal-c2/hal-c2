import { describe, expect, it } from "bun:test";

import {
  callFailed,
  commandDisplayText,
  summarizeToolCalls,
  workspaceRelative,
} from "./toolSummary.ts";

describe("commandDisplayText", () => {
  it.each([
    ["bash -lc 'git status'", "git status"],
    ['/bin/zsh -c "echo \\"hi\\""', 'echo "hi"'],
    ["sh -c 'echo '\\''it'\\'''", "echo 'it'"],
    ["sh -c ls", "ls"],
    ["bun test\n  --watch", "bun test"],
    ["bun   run    build", "bun run build"],
    // Not a wrapper: a shell running a script file.
    ["bash ./build.sh", "bash ./build.sh"],
  ])("shows %j as %j", (command, shown) => {
    expect(commandDisplayText(command)).toBe(shown);
  });
});

describe("workspaceRelative", () => {
  it("keeps paths outside the workspace whole", () => {
    expect(workspaceRelative("/workspace/shop/src/cart.ts", "/workspace/shop/")).toBe(
      "src/cart.ts",
    );
    expect(workspaceRelative("/workspace/shopping/cart.ts", "/workspace/shop")).toBe(
      "/workspace/shopping/cart.ts",
    );
    expect(workspaceRelative("/workspace/shop/cart.ts", null)).toBe("/workspace/shop/cart.ts");
  });
});

describe("callFailed", () => {
  it("is a declined call, a command that exited non-zero, or a HAL-C2 tool's error", () => {
    expect(callFailed({ type: "file_change", status: "declined" })).toBe(true);
    expect(callFailed({ type: "command_execution", status: "completed", exitCode: 0 })).toBe(false);
    expect(callFailed({ type: "command_execution", status: "completed", exitCode: 127 })).toBe(
      true,
    );
    const error = { isError: true, content: [{ type: "text", text: "thread not found" }] };
    expect(
      callFailed({ type: "dynamic_tool", toolName: "hal_c2_thread_read", output: error }),
    ).toBe(true);
    // Another server's answer is its own business.
    expect(callFailed({ type: "dynamic_tool", toolName: "linear.search", output: error })).toBe(
      false,
    );
  });
});

describe("summarizeToolCalls", () => {
  it("names a change over a look, in the order they happened", () => {
    const read = { type: "file_search", pattern: "a.ts", results: [{ fileName: "a.ts" }] };
    expect(
      summarizeToolCalls([{ type: "web_search" }, read, { type: "file_change", fileName: "a.ts" }])
        .text,
    ).toBe("Searched the web 1 time, changed 1 file, and performed 1 other action");
  });

  it("names the integrations only when every source is one", () => {
    const via = (name: string, kind: string) => ({
      type: "dynamic_tool",
      toolName: "go",
      toolSource: { key: name, name, kind },
    });
    expect(summarizeToolCalls([via("Slack", "integration"), via("Browser", "browser")]).text).toBe(
      "Used Slack and Browser",
    );
  });
});
