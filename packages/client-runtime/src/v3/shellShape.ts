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
 *
 * A `shell.rows` frame the MC marks `reset` carries all of that MC's rows, so the ones
 * it does not name are gone (the MC restarted with a new epoch, or could not resume
 * this client): the fold removes them, as the desktop's shell store does.
 */
export class ShellShapeFold {
  private sequence = 0;
  // The rows held: project ids, and thread ids with where each thread sits.
  private readonly heldProjects = new Set<string>();
  private readonly heldThreads = new Map<string, "active" | "archive">();
  private readonly mc: string;

  constructor(mc: string) {
    this.mc = mc;
  }

  shell(rows: ReadonlyArray<ShellRow>): ReadonlyArray<OrchestrationV2ShellStreamItem> {
    const projects: Array<unknown> = [];
    const threads: Array<unknown> = [];
    const archivedThreads: Array<unknown> = [];
    this.heldProjects.clear();
    this.heldThreads.clear();
    for (const [mc, id, kind, row] of rows) {
      if (mc !== this.mc) continue;
      if (kind === "project") {
        if (row.deletedAt == null) {
          projects.push(row);
          this.heldProjects.add(id);
        }
      } else if (kind === "thread" && row.deletedAt == null) {
        (row.archivedAt == null ? threads : archivedThreads).push(row);
        this.heldThreads.set(id, row.archivedAt == null ? "active" : "archive");
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
    reset = false,
  ): ReadonlyArray<OrchestrationV2ShellStreamItem> {
    if (mc !== this.mc) return [];
    const items: Array<OrchestrationV2ShellStreamItem> = [];
    if (reset) {
      const namedProjects = new Set<string>();
      const namedThreads = new Set<string>();
      for (const [id, kind] of rows) (kind === "project" ? namedProjects : namedThreads).add(id);
      // Collected before removing, so the maps are not changed while they are read.
      const goneProjects = [...this.heldProjects].filter((id) => !namedProjects.has(id));
      const goneThreads = [...this.heldThreads].filter(([id]) => !namedThreads.has(id));
      for (const projectId of goneProjects) {
        this.heldProjects.delete(projectId);
        items.push(decodeItem({ kind: "project.removed", sequence: ++this.sequence, projectId }));
      }
      for (const [threadId, location] of goneThreads) {
        this.heldThreads.delete(threadId);
        items.push(
          decodeItem({ kind: "thread.removed", sequence: ++this.sequence, location, threadId }),
        );
      }
    }
    for (const [id, kind, row] of rows) {
      const sequence = ++this.sequence;
      if (kind === "project") {
        if (row.deletedAt == null) {
          this.heldProjects.add(id);
          items.push(decodeItem({ kind: "project.updated", sequence, project: row }));
        } else {
          this.heldProjects.delete(id);
          items.push(decodeItem({ kind: "project.removed", sequence, projectId: id }));
        }
        continue;
      }
      const location = row.archivedAt == null ? "active" : "archive";
      if (row.deletedAt == null) {
        this.heldThreads.set(id, location);
        items.push(decodeItem({ kind: "thread.updated", sequence, location, thread: row }));
      } else {
        this.heldThreads.delete(id);
        items.push(decodeItem({ kind: "thread.removed", sequence, location, threadId: id }));
      }
    }
    return items;
  }
}

/**
 * The cluster shell's rows as the client holds them, across the sockets of one
 * client: each MC's rows and the [epoch, rev] they stand at. A shell sub on a new
 * socket sends `have()`, the MC answers with the rows changed since (all of an MC
 * it marks `reset`), and `answer` folds those into what is held, so every session
 * still gets the whole shell. Kept per client, as the thread streams' resume points.
 */
export class ShellRows {
  private readonly at = new Map<string, readonly [string, number]>();
  // Per MC, its rows by `kind\0id`.
  private readonly rows = new Map<string, Map<string, ShellRow>>();

  /** `{mc: [epoch, rev]}` for every MC whose rows are held. */
  have(): Readonly<Record<string, readonly [string, number]>> {
    return Object.fromEntries(this.at);
  }

  /**
   * A `shell` answer: the MCs it lists (reset unless it says otherwise) and the
   * rows the client lacked. MCs it does not list are no longer in the cluster.
   * Returns every row held.
   */
  answer(
    mcs: ReadonlyArray<Record<string, unknown>>,
    rows: ReadonlyArray<ShellRow>,
  ): ReadonlyArray<ShellRow> {
    const listed = new Set(mcs.map((entry) => String(entry.mc)));
    for (const mc of [...this.rows.keys(), ...this.at.keys()]) {
      if (!listed.has(mc)) this.forget(mc);
    }
    for (const entry of mcs) {
      const mc = String(entry.mc);
      if (entry.reset !== false) this.forget(mc);
      this.stand(mc, entry.epoch, entry.rev);
    }
    for (const [mc, id, kind, row] of rows) this.put(mc, id, kind, row);
    return [...this.rows.values()].flatMap((held) => [...held.values()]);
  }

  /** A `shell.rows` frame: brings that MC's rows to its [epoch, rev]. */
  changed(
    mc: string,
    rows: ReadonlyArray<readonly [string, string, Record<string, unknown>]>,
    reset: boolean,
    epoch: unknown,
    rev: unknown,
  ): void {
    if (reset) this.forget(mc);
    for (const [id, kind, row] of rows) this.put(mc, id, kind, row);
    this.stand(mc, epoch, rev);
  }

  /** An MC removed from the cluster: its rows are no longer part of the shell. */
  forget(mc: string): void {
    this.rows.delete(mc);
    this.at.delete(mc);
  }

  private stand(mc: string, epoch: unknown, rev: unknown): void {
    if (typeof epoch === "string" && typeof rev === "number") this.at.set(mc, [epoch, rev]);
  }

  private put(mc: string, id: string, kind: string, row: Record<string, unknown>): void {
    let held = this.rows.get(mc);
    if (held === undefined) this.rows.set(mc, (held = new Map()));
    held.set(`${kind}\u0000${id}`, [mc, id, kind, row]);
  }
}
