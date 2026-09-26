#!/usr/bin/env node

import * as NodeRuntime from "@effect/platform-node/NodeRuntime";
import * as NodeServices from "@effect/platform-node/NodeServices";
import { fromJsonStringPretty } from "@hal-c2/shared/schemaJson";
import * as Console from "effect/Console";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import { Command, Flag } from "effect/unstable/cli";

import { ListedThread, listThreads } from "./thread-transfer.ts";

const oneLine = (value: string) => value.replaceAll(/[\r\n\t]+/g, " ");
const encodeThreads = Schema.encodeEffect(fromJsonStringPretty(Schema.Array(ListedThread)));

export const listThreadsCommand = Command.make(
  "list-threads",
  {
    source: Flag.String("source").pipe(
      Flag.withDescription("Workspace root, HAL-C2 root, or data directory."),
    ),
    json: Flag.Boolean("json").pipe(
      Flag.withDefault(false),
      Flag.withDescription("Print the complete thread list as JSON."),
    ),
  },
  ({ source, json }) =>
    Effect.gen(function* () {
      const threads = yield* listThreads({ source });
      if (json) {
        yield* Console.log(yield* encodeThreads(threads));
        return;
      }
      if (threads.length === 0) {
        yield* Console.log("No threads found.");
        return;
      }
      yield* Console.log("THREAD_ID\tVERSION\tWORKSPACE\tTITLE");
      for (const thread of threads) {
        yield* Console.log(
          `${thread.id}\tv${thread.orchestrationVersion}\t${oneLine(thread.workspaceRoot)}\t${oneLine(thread.title)}`,
        );
      }
    }),
).pipe(Command.withDescription("List thread ids available for export."));

if (import.meta.main) {
  Command.run(listThreadsCommand, { version: "0.0.0" }).pipe(
    Effect.provide(NodeServices.layer),
    NodeRuntime.runMain,
  );
}
