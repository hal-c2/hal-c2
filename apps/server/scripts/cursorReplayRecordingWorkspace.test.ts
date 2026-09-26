import { assert, it } from "@effect/vitest";

import {
  cursorReplayPromptsForWorkspace,
  cursorReplayTranscriptCwd,
  shouldSeedCursorReplayWorkspace,
} from "./cursorReplayRecordingWorkspace.ts";

it("points the read-only prompt at the unique recording workspace", () => {
  assert.deepEqual(
    cursorReplayPromptsForWorkspace({
      scenario: "tool_call_read_only",
      configuredPrompts: ["stale global path"],
      packageJsonPath: "/tmp/hal-c2-cursor-owned-abc123/package.json",
      tsconfigPath: "/tmp/hal-c2-cursor-owned-abc123/tsconfig.json",
    }),
    [
      "Read /tmp/hal-c2-cursor-owned-abc123/package.json and /tmp/hal-c2-cursor-owned-abc123/tsconfig.json, then answer exactly: read only tool fixture complete",
    ],
  );
});

it("never seeds files into an externally supplied workspace", () => {
  assert.isFalse(
    shouldSeedCursorReplayWorkspace({
      scenario: "tool_call_read_only",
      owned: false,
    }),
  );
  assert.isTrue(
    shouldSeedCursorReplayWorkspace({
      scenario: "tool_call_read_only",
      owned: true,
    }),
  );
});

it("canonicalizes read-only tool paths to the stable fixture workspace", () => {
  assert.equal(
    cursorReplayTranscriptCwd("tool_call_read_only"),
    "/tmp/claude-replay-tool_call_read_only",
  );
  assert.equal(cursorReplayTranscriptCwd("simple"), undefined);
});
