import { describe, expect, it } from "vite-plus/test";

import {
  HAL_C2_MCP_TOOL_NAMES,
  resolveHalC2McpToolPresentation,
} from "./halC2McpToolPresentation.ts";

describe("resolveHalC2McpToolPresentation", () => {
  it("recognizes every HAL-C2 tool across provider prefixes and completion suffixes", () => {
    for (const tool of HAL_C2_MCP_TOOL_NAMES) {
      const presentation = resolveHalC2McpToolPresentation(tool);
      for (const prefix of [
        "mcp__hal-c2__",
        "mcp__hal_c2__",
        "mcp__halc2__",
        "HAL-C2.",
        "halc2/",
        "hal-c2:",
        "mcp_hal-c2_",
        "HAL-C2 ",
        "hal-c2 · ",
      ]) {
        expect(resolveHalC2McpToolPresentation(`${prefix}${tool} completed`), tool).toEqual(
          presentation,
        );
      }
      expect(resolveHalC2McpToolPresentation(`mcp__another-server__${tool}`), tool).toBeNull();
    }
  });
  it("pretty prints Claude and Cursor HAL-C2 MCP tool names", () => {
    expect(resolveHalC2McpToolPresentation("mcp__hal-c2__hal_c2_thread_read")).toEqual({
      displayName: "Read a HAL-C2 thread",
      logo: "hal-c2",
    });
  });

  it("pretty prints Codex HAL-C2 MCP tool names", () => {
    expect(resolveHalC2McpToolPresentation("hal-c2.create_threads")).toEqual({
      displayName: "Create HAL-C2 threads",
      logo: "hal-c2",
    });
  });

  it("pretty prints thread metadata updates", () => {
    expect(resolveHalC2McpToolPresentation("mcp__hal-c2__hal_c2_thread_update")).toEqual({
      displayName: "Update HAL-C2 thread metadata",
      logo: "hal-c2",
    });
  });

  it("pretty prints bare HAL-C2 MCP toolkit names", () => {
    expect(resolveHalC2McpToolPresentation("list_scheduled_tasks")).toEqual({
      displayName: "List scheduled tasks",
      logo: "hal-c2",
    });
  });

  it("pretty prints worktree HAL-C2 MCP tool names", () => {
    expect(resolveHalC2McpToolPresentation("mcp__hal-c2__hal_c2_worktree_handoff")).toEqual({
      displayName: "Hand off thread to a git worktree",
      logo: "hal-c2",
    });
    expect(resolveHalC2McpToolPresentation("hal-c2.hal_c2_worktree_status")).toEqual({
      displayName: "Get thread worktree status",
      logo: "hal-c2",
    });
  });

  it("pretty prints preview HAL-C2 MCP tool names", () => {
    expect(resolveHalC2McpToolPresentation("HAL-C2.preview_open")).toEqual({
      displayName: "Open a page in the preview browser",
      logo: "hal-c2",
    });
    expect(resolveHalC2McpToolPresentation("mcp__hal-c2__preview_status")).toEqual({
      displayName: "Get preview browser status",
      logo: "hal-c2",
    });
  });

  it("matches the separator variants ACP registry agents emit", () => {
    for (const name of [
      "mcp_hal-c2_delegate_task",
      "halc2:delegate_task",
      "hal-c2/delegate_task",
      "hal-c2 delegate_task",
      "HAL-C2 delegate_task",
      "hal-c2__delegate_task",
    ]) {
      expect(resolveHalC2McpToolPresentation(name)?.displayName).toBe("Delegate a child task");
    }
  });

  it("keeps unknown MCP tools on the generic renderer path", () => {
    expect(resolveHalC2McpToolPresentation("mcp__github__search_issues")).toBeNull();
    expect(resolveHalC2McpToolPresentation("hal-c2.not_a_real_tool")).toBeNull();
  });
});
