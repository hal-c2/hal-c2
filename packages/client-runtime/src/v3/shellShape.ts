import { OrchestrationV2ShellStreamItem } from "@hal-c2/contracts";
import * as Schema from "effect/Schema";

/** A protocol-3 shell row: `[mc, streamId, kind, row]` ("project" or "thread"). */
export type ShellRow = readonly [string, string, string, Record<string, unknown>];

const decodeItem = Schema.decodeUnknownSync(Schema.toCodecJson(OrchestrationV2ShellStreamItem));

/**
 * One MC's slice of the protocol-3 cluster shell, as the v2 shell stream items the
 * environment shell state already consumes.
 *
 * The cluster shell carries every MC's rows; each environment keeps only its own
 * MC's. Sequences are local to this fold: a snapshot resets them and every later
 * row is numbered after it, which is all the shell reducer compares.
 */
export class ShellShapeFold {
  private sequence = 0;
  private readonly mc: string;

  constructor(mc: string) {
    this.mc = mc;
  }

  shell(rows: ReadonlyArray<ShellRow>): ReadonlyArray<OrchestrationV2ShellStreamItem> {
    const projects: Array<unknown> = [];
    const threads: Array<unknown> = [];
    const archivedThreads: Array<unknown> = [];
    for (const [mc, , kind, row] of rows) {
      if (mc !== this.mc) continue;
      if (kind === "project") {
        if (row.deletedAt == null) projects.push(row);
      } else if (kind === "thread" && row.deletedAt == null) {
        (row.archivedAt == null ? threads : archivedThreads).push(row);
      }
    }
    this.sequence++;
    return [
      decodeItem({
        kind: "snapshot",
        snapshot: {
          schemaVersion: 1,
          snapshotSequence: this.sequence,
          projects,
          threads,
          archivedThreads,
        },
      }),
      { kind: "synchronized" },
    ];
  }

  rows(
    mc: string,
    rows: ReadonlyArray<readonly [string, string, Record<string, unknown>]>,
  ): ReadonlyArray<OrchestrationV2ShellStreamItem> {
    if (mc !== this.mc) return [];
    return rows.map(([id, kind, row]) => {
      const sequence = ++this.sequence;
      if (kind === "project")
        return row.deletedAt == null
          ? decodeItem({ kind: "project.updated", sequence, project: row })
          : decodeItem({ kind: "project.removed", sequence, projectId: id });
      const location = row.archivedAt == null ? "active" : "archive";
      return row.deletedAt == null
        ? decodeItem({ kind: "thread.updated", sequence, location, thread: row })
        : decodeItem({ kind: "thread.removed", sequence, location, threadId: id });
    });
  }
}
