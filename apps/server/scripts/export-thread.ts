#!/usr/bin/env node

import * as NodeRuntime from "@effect/platform-node/NodeRuntime";
import * as NodeServices from "@effect/platform-node/NodeServices";
import * as Console from "effect/Console";
import * as Effect from "effect/Effect";
import { Command, Flag } from "effect/unstable/cli";

import { exportThread, ThreadTransferState } from "./thread-transfer.ts";

export const exportThreadCommand = Command.make(
  "export-thread",
  {
    source: Flag.String("source").pipe(
      Flag.withDescription("Workspace root, HAL-C2 base directory, or direct state directory."),
    ),
    state: Flag.Literals("state", ThreadTransferState.literals).pipe(
      Flag.withDefault("userdata"),
      Flag.withDescription(
        "State directory below the HAL-C2 base directory; defaults to userdata.",
      ),
    ),
    threadId: Flag.String("thread-id"),
    output: Flag.String("output").pipe(Flag.withDescription("Archive JSON file to create.")),
    includeTerminalLogs: Flag.Boolean("include-terminal-logs").pipe(
      Flag.withDefault(false),
      Flag.withDescription("Include persisted terminal history, which may contain secrets."),
    ),
  },
  ({ source, state, threadId, output, includeTerminalLogs }) =>
    Effect.gen(function* () {
      const result = yield* exportThread({
        source,
        state,
        threadId,
        output,
        includeTerminalLogs,
      });
      yield* Console.log(
        `Exported '${result.title}' (${result.threadId}, orchestrator v${result.orchestrationVersion}) to ${result.output}`,
      );
      yield* Console.log(
        `  ${result.eventCount} events, ${result.attachmentCount} attachments, ${result.terminalLogCount} terminal logs`,
      );
    }),
).pipe(Command.withDescription("Export one HAL-C2 thread and its supporting files."));

if (import.meta.main) {
  Command.run(exportThreadCommand, { version: "0.0.0" }).pipe(
    Effect.provide(NodeServices.layer),
    NodeRuntime.runMain,
  );
}
