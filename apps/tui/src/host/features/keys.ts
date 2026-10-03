import {
  chordLabel,
  describeAction,
  KEYBINDING_GROUPS,
  KEYMAP_LAYERS,
  KEYMAP_PARITY,
  LEADER_ACTIONS,
  normalizeChord,
  rebindLayers,
  type KeymapLayer,
} from "../../keymap.ts";
import type { TuiMode } from "../layoutState.ts";
import { payloadField, type Feature, type FeatureKit } from "./kit.ts";

/**
 * The keys themselves: help for what has focus (F1), the leader layer (^X)
 * and rebinding a chord from the client. Owns the published `keybindings`
 * layers, which ShellKeymap binds, so a rebind is live at once.
 */
export function createKeysFeature(
  kit: FeatureKit,
  options: {
    /** Persist a rebind (`{ chord: action | null }`) to the user's keymap.json. */
    readonly saveKeymap?: ((overrides: Record<string, string | null>) => void) | undefined;
  },
): Feature {
  let layers: Record<string, KeymapLayer> = KEYMAP_LAYERS;
  const publish = () =>
    kit.state.set("keybindings", {
      layers,
      groups: KEYBINDING_GROUPS,
      parity: KEYMAP_PARITY,
    });

  /** The chords live in `mode`: its layer, over the global one everywhere but the terminal. */
  const chordsFor = (mode: TuiMode): Array<[string, string]> => {
    const own = Object.entries(layers[mode] ?? {});
    const global = mode === "terminal" ? [] : Object.entries(layers.global ?? {});
    const seen = new Set(own.map(([chord]) => chord));
    return [...own, ...global.filter(([chord]) => !seen.has(chord))];
  };

  const openHelp = () => {
    const mode = kit.mode();
    kit.menu({
      title: `keys · ${mode}`,
      options: chordsFor(mode).map(([chord, action]) => ({
        label: chordLabel(chord),
        description: describeAction(action, mode),
        value: chord,
      })),
      onChoose: () => {},
      returnMode: mode,
    });
  };

  const openLeader = () => {
    const returnMode = kit.mode();
    kit.menu({
      title: "^X",
      options: LEADER_ACTIONS.map((entry) => ({
        label: `${entry.key}  ${entry.title}`,
        value: entry.key,
      })),
      onChoose: (key) => runLeader(key),
      mode: "leader",
      returnMode,
    });
  };
  const runLeader = (key: string) => {
    const entry = LEADER_ACTIONS.find((candidate) => candidate.key === key);
    kit.closeMenu("^X");
    if (entry) kit.dispatch(entry.action);
  };

  /** Every action the prompt's chords run, with what the reference calls it. */
  const rebindable = () => {
    const actions = new Map<string, string>();
    for (const [, action] of chordsFor("compose")) {
      if (!actions.has(action)) actions.set(action, describeAction(action, "compose"));
    }
    return [...actions].map(([action, title]) => ({ action, title }));
  };
  const chordsOf = (action: string) =>
    chordsFor("compose")
      .filter(([, bound]) => bound === action)
      .map(([chord]) => chordLabel(chord))
      .join(", ");

  const askChord = (action: string, title: string) =>
    kit.ask({
      label: `key for ${title}`,
      placeholder: "A chord, like Ctrl+T",
      returnMode: kit.mode() === "ask" ? "compose" : kit.mode(),
      onSubmit: (text) => rebind(action, title, text),
    });

  const rebind = (action: string, title: string, text: string) => {
    const chord = normalizeChord(text);
    if (chord === null) {
      kit.status(`"${text}" is not a key chord.`, "error");
      return;
    }
    const owner = chordsFor("compose").find(
      ([bound, boundAction]) =>
        boundAction !== action && bound.split(",").some((part) => part.trim() === chord),
    );
    if (owner) {
      kit.status(
        `${chordLabel(chord)} is already ${describeAction(owner[1], "compose")}.`,
        "error",
      );
      return;
    }
    const result = rebindLayers(layers, action, chord);
    layers = result.layers;
    publish();
    options.saveKeymap?.({
      ...Object.fromEntries(result.freed.map((old) => [old, null])),
      [chord]: action,
    });
    kit.status(`${title} → ${chordLabel(chord)}`, "success");
  };

  const openRebind = () => {
    const returnMode = kit.mode();
    kit.menu({
      title: "rebind",
      options: rebindable().map((entry) => ({
        label: entry.title,
        description: chordsOf(entry.action),
        value: entry.action,
      })),
      onChoose: (action) =>
        askChord(action, rebindable().find((entry) => entry.action === action)?.title ?? action),
      returnMode,
    });
  };

  publish();
  return {
    commands: () => [
      { id: "help.open", title: "Keys for what has focus", hint: "F1", action: "help.open" },
      {
        id: "keymap.rebind",
        title: "Rebind a key…",
        keywords: "keybinding shortcut chord keymap",
        action: "keymap.rebind.open",
      },
    ],
    dispatch: (action, payload) => {
      const leader = /^leader\.run\.(.+)$/.exec(action);
      if (leader) {
        runLeader(leader[1]!);
        return true;
      }
      switch (action) {
        case "help.open":
          openHelp();
          return true;
        case "leader.open":
          openLeader();
          return true;
        case "leader.cancel":
          kit.closeMenu("^X");
          return true;
        case "keymap.rebind.open":
          openRebind();
          return true;
        case "keymap.rebind": {
          const target = payloadField(payload, "action");
          const chord = payloadField(payload, "chord");
          if (typeof target !== "string" || typeof chord !== "string") return true;
          rebind(
            target,
            rebindable().find((entry) => entry.action === target)?.title ?? target,
            chord,
          );
          return true;
        }
        default:
          return false;
      }
    },
  };
}
