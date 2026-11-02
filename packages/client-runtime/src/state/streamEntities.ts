// The entities of one MC stream (a Space, the Spaces index), held from its
// snapshot and the events after it. Pure: a fold over the stream's frames.
import { applyPatch, type Patch } from "../v3/patch.ts";

/** One entity as the MC sent it. */
export type StreamEntity = Readonly<Record<string, unknown>>;

/** A stream frame, as `mcStream` delivers them. */
export type EntityStreamFrame =
  | {
      /** Part 0 starts a new snapshot that replaces everything held; `done` ends it. */
      readonly type: "snapshot";
      readonly part: number;
      readonly done: boolean;
      readonly offset: number;
      readonly rows: ReadonlyArray<readonly [kind: string, id: string, entity: StreamEntity]>;
    }
  | {
      readonly type: "events";
      readonly events: ReadonlyArray<
        readonly [seq: number, kind: string, id: string, patch: Patch, atMs: number]
      >;
    }
  /** The stream caught up with the MC: everything since the snapshot was sent. */
  | { readonly type: "live" };

export interface StreamEntities {
  /** Entities by kind, then id, in the order they first arrived. */
  readonly kinds: ReadonlyMap<string, ReadonlyMap<string, StreamEntity>>;
  /** The newest event (or snapshot) offset applied; events at or below it are replays. */
  readonly offset: number;
  /** A whole snapshot has arrived. */
  readonly ready: boolean;
  /** A snapshot whose later parts have not come yet; events apply to it meanwhile. */
  readonly pending: ReadonlyMap<string, ReadonlyMap<string, StreamEntity>> | null;
}

export const EMPTY_STREAM_ENTITIES: StreamEntities = {
  kinds: new Map(),
  offset: 0,
  ready: false,
  pending: null,
};

/** The entities of `kind`, in arrival order. */
export function entitiesOf(state: StreamEntities, kind: string): ReadonlyArray<StreamEntity> {
  return [...(state.kinds.get(kind)?.values() ?? [])];
}

/** The entity `kind`/`id`, or undefined. */
export function entityOf(
  state: StreamEntities,
  kind: string,
  id: string,
): StreamEntity | undefined {
  return state.kinds.get(kind)?.get(id);
}

/**
 * Folds one frame in. A snapshot (part 0) replaces what is held once its last
 * part comes; events apply in sequence, and an event the state already holds
 * (a resumed subscription replaying from an older offset) is skipped.
 */
export function foldStreamEntities(
  state: StreamEntities,
  frame: EntityStreamFrame,
): StreamEntities {
  switch (frame.type) {
    case "snapshot": {
      const base = frame.part === 0 ? new Map() : copyKinds(state.pending ?? new Map());
      for (const [kind, id, entity] of frame.rows) kindOf(base, kind).set(id, entity);
      return frame.done
        ? { kinds: base, offset: frame.offset, ready: true, pending: null }
        : { ...state, offset: frame.offset, pending: base };
    }
    case "events": {
      const fresh = frame.events.filter(([seq]) => seq > state.offset);
      if (fresh.length === 0) return state;
      const target = copyKinds(state.pending ?? state.kinds);
      let offset = state.offset;
      for (const [seq, kind, id, patch] of fresh) {
        if (seq <= offset) continue;
        offset = seq;
        const entities = kindOf(target, kind);
        const next = applyPatch(entities.get(id), patch);
        if (next === null) entities.delete(id);
        else entities.set(id, next);
      }
      return state.pending === null
        ? { ...state, kinds: target, offset }
        : { ...state, pending: target, offset };
    }
    case "live":
      return state;
  }
}

function copyKinds(
  kinds: ReadonlyMap<string, ReadonlyMap<string, StreamEntity>>,
): Map<string, Map<string, StreamEntity>> {
  return new Map([...kinds].map(([kind, entities]) => [kind, new Map(entities)]));
}

function kindOf(
  kinds: Map<string, Map<string, StreamEntity>>,
  kind: string,
): Map<string, StreamEntity> {
  let entities = kinds.get(kind);
  if (entities === undefined) {
    entities = new Map();
    kinds.set(kind, entities);
  }
  return entities;
}
