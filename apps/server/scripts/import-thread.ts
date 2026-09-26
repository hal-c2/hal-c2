#!/usr/bin/env node

import * as NodeRuntime from "@effect/platform-node/NodeRuntime";
import * as NodeServices from "@effect/platform-node/NodeServices";
import * as Console from "effect/Console";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import { Command, Flag } from "effect/unstable/cli";

import { importThread } from "./thread-transfer.ts";

export const importThreadCommand = Command.make(
  "import-thread",
  {
    archive: Flag.String("archive").pipe(Flag.withDescription("Thread archive JSON to import.")),
    destination: Flag.String("destination").pipe(
      Flag.withDescription("Workspace root, HAL-C2 root, or data directory."),
    ),
    targetProjectId: Flag.String("target-project-id").pipe(
      Flag.optional,
      Flag.withDescription("Project id when it cannot be inferred from the destination path."),
    ),
  },
  ({ archive, destination, targetProjectId }) =>
    Effect.gen(function* () {
      const result = yield* importThread({
        archive,
        destination,
        targetProjectId: Option.getOrUndefined(targetProjectId),
      });
      yield* Console.log(
        `Imported '${result.title}' (${result.threadId}, orchestrator v${result.orchestrationVersion}) into ${result.targetProjectTitle}`,
      );
      yield* Console.log(
        `  ${result.eventCount} events, ${result.attachmentCount} attachments, ${result.terminalLogCount} terminal logs`,
      );
      yield* Console.log(`  Database backup: ${result.backup}`);
      yield* Console.log(
        "Restart the destination HAL-C2 server so its projector reads the new events.",
      );
    }),
).pipe(Command.withDescription("Import one HAL-C2 thread into an isolated project database."));

if (import.meta.main) {
  Command.run(importThreadCommand, { version: "0.0.0" }).pipe(
    Effect.provide(NodeServices.layer),
    NodeRuntime.runMain,
  );
}
