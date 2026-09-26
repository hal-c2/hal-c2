import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, describe, it } from "@effect/vitest";
import { EnvironmentId, ProviderInstanceId, ThreadId } from "@hal-c2/contracts";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";

import {
  PI_HAL_C2_MCP_EXTENSION_FILENAME,
  HAL_C2_MCP_BEARER_ENV,
  HAL_C2_MCP_URL_ENV,
  HAL_C2_PI_RUNTIME_MODE_ENV,
} from "./piHalC2McpExtensionSource.ts";
import {
  buildPiRpcLaunch,
  materializePiHalC2McpExtension,
  resolvePiLaunchArgs,
} from "./piHalC2McpInjection.ts";

const threadId = ThreadId.make("thread-pi-hal-c2-mcp");

const mcpSession = {
  environmentId: EnvironmentId.make("environment-pi-hal-c2-mcp"),
  threadId,
  providerSessionId: "mcp-session-pi",
  providerInstanceId: ProviderInstanceId.make("pi"),
  endpoint: "http://127.0.0.1:43123/mcp",
  authorizationHeader: "Bearer secret-pi-token",
  browserToolsAvailable: true,
};

describe("pi HAL-C2 MCP injection", () => {
  it("always adds the permission bridge and configures MCP when available", () => {
    const resolvedArgs = resolvePiLaunchArgs(
      "--extension=/home/user/.pi/agent/extensions/demo.ts --session-dir=/tmp/pi-sessions --provider=anthropic --model=claude-sonnet --tools='' --name=-review --extension-flag=kept",
    );
    assert.isTrue(resolvedArgs.ok);
    if (!resolvedArgs.ok) return;
    const launch = buildPiRpcLaunch({
      launchArgs: resolvedArgs.args,
      environment: { PATH: "/usr/bin" },
      mcpSession,
      extensionPath: "/tmp/cache/pi-hal-c2-mcp-extension.ts",
      runtimeMode: "approval-required",
    });
    assert.deepEqual(launch.args, [
      "--mode",
      "rpc",
      "--extension",
      "/home/user/.pi/agent/extensions/demo.ts",
      "--session-dir",
      "/tmp/pi-sessions",
      "--provider",
      "anthropic",
      "--model",
      "claude-sonnet",
      "--tools",
      "",
      "--name",
      "-review",
      "--extension-flag=kept",
      "--extension",
      "/tmp/cache/pi-hal-c2-mcp-extension.ts",
    ]);
    assert.notInclude(launch.args, "--no-extensions");
    assert.equal(launch.env[HAL_C2_MCP_URL_ENV], "http://127.0.0.1:43123/mcp");
    assert.equal(launch.env[HAL_C2_MCP_BEARER_ENV], "secret-pi-token");
    assert.equal(launch.env[HAL_C2_PI_RUNTIME_MODE_ENV], "approval-required");

    const permissionOnly = buildPiRpcLaunch({
      launchArgs: [],
      environment: {
        [HAL_C2_MCP_URL_ENV]: "http://127.0.0.1:9999/stale",
        [HAL_C2_MCP_BEARER_ENV]: "stale-token",
      },
      mcpSession: undefined,
      extensionPath: "/tmp/cache/pi-hal-c2-mcp-extension.ts",
      runtimeMode: "auto-accept-edits",
    });
    assert.deepEqual(permissionOnly.args, [
      "--mode",
      "rpc",
      "--extension",
      "/tmp/cache/pi-hal-c2-mcp-extension.ts",
    ]);
    assert.isFalse(permissionOnly.hasHalC2Mcp);
    assert.isUndefined(permissionOnly.env[HAL_C2_MCP_URL_ENV]);
    assert.isUndefined(permissionOnly.env[HAL_C2_MCP_BEARER_ENV]);
    assert.equal(permissionOnly.env[HAL_C2_PI_RUNTIME_MODE_ENV], "auto-accept-edits");
  });

  it("falls back to Pi's first supported mode for legacy auto threads", () => {
    const launch = buildPiRpcLaunch({
      launchArgs: [],
      environment: {},
      mcpSession: undefined,
      extensionPath: "/tmp/cache/pi-hal-c2-mcp-extension.ts",
      runtimeMode: "auto",
    });

    assert.equal(launch.env[HAL_C2_PI_RUNTIME_MODE_ENV], "approval-required");
  });

  it("forces tools and user extensions off for unattended text generation", () => {
    const launch = buildPiRpcLaunch({
      launchArgs: [
        "--tools",
        "read,write",
        "--extension",
        "/home/user/.pi/agent/extensions/demo.ts",
        "--extension=./second.ts",
        "--provider",
        "anthropic",
      ],
      environment: {},
      mcpSession,
      extensionPath: "/tmp/cache/pi-hal-c2-mcp-extension.ts",
      ephemeral: true,
      disableExtensions: true,
      disableTools: true,
    });
    assert.deepEqual(launch.args, [
      "--mode",
      "rpc",
      "--no-session",
      "--provider",
      "anthropic",
      "--no-extensions",
      "--no-tools",
    ]);
    assert.isFalse(launch.hasHalC2Mcp);
    assert.deepInclude(resolvePiLaunchArgs("--mode text"), {
      ok: false,
      message: "Pi launch argument '--mode' is controlled by HAL-C2 and cannot be overridden.",
    });
    assert.deepInclude(resolvePiLaunchArgs("--session old.jsonl"), { ok: false });
    assert.deepInclude(resolvePiLaunchArgs("prompt pi immediately"), { ok: false });
    assert.deepInclude(resolvePiLaunchArgs("--plan @instructions.md"), { ok: false });
  });

  it.effect("materializes the MCP bridge with namespaced tool registration", () =>
    Effect.gen(function* () {
      const fs = yield* FileSystem.FileSystem;
      const cacheDir = yield* fs.makeTempDirectoryScoped({ prefix: "hal-c2-pi-extensions-" });
      const mcpDest = yield* materializePiHalC2McpExtension(cacheDir);
      assert.isTrue(mcpDest.endsWith(PI_HAL_C2_MCP_EXTENSION_FILENAME));
      const mcpSource = yield* fs.readFileString(mcpDest);
      assert.include(mcpSource, "export default async function halC2McpExtension");
      assert.include(mcpSource, "before_agent_start");
      assert.include(mcpSource, 'pi.on("tool_call"');
      assert.include(mcpSource, "Allow ${event.toolName}?");
      assert.include(mcpSource, '"mcp-protocol-version"');
      assert.include(mcpSource, '"tools/call"');
      assert.include(mcpSource, "mcp__hal-c2__");
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  );
});
