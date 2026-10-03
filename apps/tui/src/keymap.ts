// The terminal client's keymap: the chords each input mode binds (published to
// QML as `keybindings.layers`, one `Keymap` per mode in ShellKeymap.qml) and the
// reference grouped by context that the Settings overlay lists. Every chord a
// layer binds must appear in the reference (`chords`); keymap.test.ts checks it.

export interface KeyBinding {
  /** How the reference shows the chord. */
  readonly keys: string;
  readonly description: string;
  /** The Keymap chords this entry documents (opentui-qml key strings). */
  readonly chords?: ReadonlyArray<string>;
}

export interface KeyBindingGroup {
  readonly title: string;
  readonly bindings: ReadonlyArray<KeyBinding>;
}

export const KEYBINDING_GROUPS: ReadonlyArray<KeyBindingGroup> = [
  {
    title: "Global",
    bindings: [
      { keys: "^C", description: "Quit", chords: ["ctrl+c"] },
      { keys: "^K", description: "Command palette", chords: ["ctrl+k"] },
      { keys: "^N", description: "New thread", chords: ["ctrl+n"] },
      { keys: "^F", description: "Filter threads", chords: ["ctrl+f"] },
      { keys: "^L", description: "Toggle source-control panel", chords: ["ctrl+l"] },
      { keys: "F1", description: "Keys for what has focus", chords: ["f1"] },
      {
        keys: "^X …",
        description:
          "Leader: n new · k commands · f filter · l panel · e terminal · s settings · b files",
        chords: ["ctrl+x", "n", "k", "f", "l", "e", "s", "b"],
      },
    ],
  },
  {
    title: "Conversation",
    bindings: [
      { keys: "Alt+↑/↓", description: "Previous / next thread", chords: ["alt+up", "alt+down"] },
      {
        keys: "Alt+1…9",
        description: "Jump to the Nth thread",
        chords: ["alt+1", "alt+2", "alt+3", "alt+4", "alt+5", "alt+6", "alt+7", "alt+8", "alt+9"],
      },
      { keys: "PgUp/PgDn", description: "Scroll the conversation", chords: ["pageup", "pagedown"] },
      { keys: "Enter", description: "Send the reply", chords: ["return"] },
      {
        keys: "↑/↓",
        description: "Earlier prompts · walk approvals when the prompt is empty",
        chords: ["up", "down"],
      },
      { keys: "^G", description: "Edit the prompt in $EDITOR", chords: ["ctrl+g"] },
      { keys: "^↑/^↓", description: "Resize the prompt", chords: ["ctrl+up", "ctrl+down"] },
      {
        keys: "^B / Shift+Tab",
        description: "Toggle plan / build mode",
        chords: ["ctrl+b", "shift+tab"],
      },
      { keys: "^O", description: "Runtime access picker", chords: ["ctrl+o"] },
      { keys: "Ctrl+Shift+M", description: "Model picker", chords: ["ctrl+shift+m"] },
      { keys: "Ctrl+Shift+E", description: "Effort picker", chords: ["ctrl+shift+e"] },
      { keys: "^Y", description: "Implement the proposed plan", chords: ["ctrl+y"] },
      { keys: "^A / ^R", description: "Approve / decline a request", chords: ["ctrl+a", "ctrl+r"] },
      {
        keys: "^S / ^X",
        description: "Always allow a request this session / cancel it",
        chords: ["ctrl+s", "ctrl+x"],
      },
      { keys: "^U", description: "Reopen a pending question", chords: ["ctrl+u"] },
      { keys: "Space", description: "Question: toggle an option", chords: ["space"] },
      { keys: "Esc", description: "Clear the draft / stop the turn", chords: ["escape"] },
    ],
  },
  {
    title: "Terminal",
    bindings: [
      { keys: "^E", description: "Show / hide the terminal", chords: ["ctrl+e"] },
      { keys: "^P", description: "Focus prompt ⇄ terminal", chords: ["ctrl+p"] },
      { keys: "^↑/^↓", description: "Resize the terminal", chords: ["ctrl+up", "ctrl+down"] },
      { keys: "^O", description: "Copy the terminal viewport", chords: ["ctrl+o"] },
      {
        keys: "Shift+PgUp/PgDn · Shift+↑/↓",
        description: "Scroll the scrollback by a page / a line",
        chords: ["shift+pageup", "shift+pagedown", "shift+up", "shift+down"],
      },
      { keys: "tabs", description: "Click a number to switch · ✕ close · + new" },
    ],
  },
  {
    title: "Source control",
    bindings: [
      { keys: "↑/↓", description: "Move between git actions", chords: ["up", "down"] },
      { keys: "Enter", description: "Run the action / copy the PR link", chords: ["return"] },
      { keys: "Esc", description: "Return to the conversation", chords: ["escape"] },
      { keys: "^L", description: "Close the panel", chords: ["ctrl+l"] },
      { keys: "x", description: "Dismiss the last action's log", chords: ["x"] },
    ],
  },
  {
    title: "Overlays (palette / diff / files / pickers)",
    bindings: [
      { keys: "↑/↓ · j/k", description: "Move the selection", chords: ["up", "down", "j", "k"] },
      { keys: "Enter · →", description: "Run / open / apply", chords: ["return", "right"] },
      { keys: "← · Backspace", description: "Files: up a folder", chords: ["left", "backspace"] },
      {
        keys: "PgUp/PgDn",
        description: "Scroll a file, diff or settings",
        chords: ["pageup", "pagedown"],
      },
      { keys: "Esc", description: "Back / close", chords: ["escape"] },
      { keys: "^P", description: "Back to the prompt from any pane", chords: ["ctrl+p"] },
      { keys: "s", description: "Diff: toggle split / stacked", chords: ["s"] },
      { keys: "y / n", description: "Delete a thread: confirm / keep", chords: ["y", "n"] },
      {
        keys: "r",
        description: "Settings: rebind a key · Files: list again · Diff: load again",
        chords: ["r"],
      },
      { keys: "e", description: "Files: edit in $EDITOR", chords: ["e"] },
      {
        keys: "Tab · ^Enter",
        description: "Add project: browse ⇄ edit · run the action",
        chords: ["tab", "ctrl+return"],
      },
      {
        keys: "j/k · ↑/↓ · Esc",
        description: "Thread list: next / previous · back to the prompt",
        chords: ["j", "k", "up", "down", "escape"],
      },
    ],
  },
];

/** Chord → host action, per input mode (`Shell.state.mode`). */
export type KeymapLayer = Readonly<Record<string, string>>;

const THREAD_JUMPS: KeymapLayer = Object.fromEntries(
  Array.from({ length: 9 }, (_, index) => [`alt+${index + 1}`, `thread.jump.${index + 1}`]),
);

/** The keys that can follow the leader (^X), and the host action each runs. */
export const LEADER_ACTIONS: ReadonlyArray<{
  readonly key: string;
  readonly title: string;
  readonly action: string;
}> = [
  { key: "n", title: "New thread", action: "thread.new" },
  { key: "k", title: "Command palette", action: "palette.open" },
  { key: "f", title: "Filter threads", action: "sidebar.filter.focus" },
  { key: "l", title: "Source-control panel", action: "rightPanel.toggle" },
  { key: "e", title: "Terminal", action: "terminal.toggle" },
  { key: "s", title: "Settings", action: "settings.open" },
  { key: "b", title: "Browse files", action: "files.open" },
];

const LEADER_LAYER: KeymapLayer = {
  ...Object.fromEntries(LEADER_ACTIONS.map((entry) => [entry.key, `leader.run.${entry.key}`])),
  up: "select.previous",
  down: "select.next",
  return: "select.confirm",
  escape: "leader.cancel",
};

/**
 * The prompt's chords (a reply or a new-thread draft). Keys an action cannot
 * use right now (↑/↓ without two approvals, ^A with nothing to approve, ^P
 * with the terminal hidden) are declined by the host and reach the editor.
 */
const COMPOSE: KeymapLayer = {
  "ctrl+k": "palette.open",
  "ctrl+n": "thread.new",
  "ctrl+f": "sidebar.filter.focus",
  "ctrl+l": "rightPanel.toggle",
  "ctrl+e": "terminal.toggle",
  "ctrl+p": "terminal.focus",
  "alt+up": "thread.previous",
  "alt+down": "thread.next",
  ...THREAD_JUMPS,
  pageup: "timeline.pageUp",
  pagedown: "timeline.pageDown",
  up: "approval.previous",
  down: "approval.next",
  "ctrl+up": "composer.grow",
  "ctrl+down": "composer.shrink",
  "ctrl+b, shift+tab": "composer.interactionMode.toggle",
  "ctrl+o": "composer.runtimePicker.toggle",
  "ctrl+shift+m": "composer.modelPicker.toggle",
  "ctrl+shift+e": "composer.effortPicker.toggle",
  "ctrl+g": "composer.editor.open",
  "ctrl+y": "plan.implement",
  "ctrl+a": "approval.approve",
  "ctrl+r": "approval.decline",
  "ctrl+s": "approval.approveSession",
  "ctrl+x": "approval.cancel",
  "ctrl+u": "userInput.reopen",
  escape: "composer.escape",
  return: "composer.submit",
};

/**
 * The chords each mode binds: the one source of the client's keys (no brick
 * declares its own Shortcut). Plain printable and editing keys reach a focused
 * prompt or field when no chord takes them.
 */
export const KEYMAP_LAYERS = {
  /**
   * Under every mode but the terminal drawer, which passes ^C to the shell.
   * "quit" is the action keymap.json files name (the host runs it as app.quit).
   */
  // ^X cancels a pending approval at the prompt (COMPOSE); with none the host
  // declines that, the key falls through to here, and it opens the leader layer.
  global: {
    "ctrl+c": "quit",
    "ctrl+p": "composer.focus",
    f1: "help.open",
    "ctrl+x": "leader.open",
  },
  compose: COMPOSE,
  newThread: COMPOSE,
  userInput: {
    up: "userInput.previous",
    down: "userInput.next",
    space: "userInput.toggle",
    return: "userInput.submit",
    escape: "userInput.defer",
  },
  revert: {
    up: "checkpoint.revert.previous",
    down: "checkpoint.revert.next",
    return: "checkpoint.revert.confirm",
    escape: "checkpoint.revert.cancel",
  },
  terminal: {
    "ctrl+e": "terminal.toggle",
    "ctrl+p": "terminal.focus.toggle",
    "ctrl+up": "terminal.grow",
    "ctrl+down": "terminal.shrink",
    "ctrl+o": "terminal.copy",
    f1: "help.open",
    "shift+pageup": "terminal.scroll.pageUp",
    "shift+pagedown": "terminal.scroll.pageDown",
    "shift+up": "terminal.scroll.lineUp",
    "shift+down": "terminal.scroll.lineDown",
  },
  command: {
    up: "palette.previous",
    down: "palette.next",
    return: "palette.run",
    escape: "palette.close",
    "ctrl+k": "palette.open",
  },
  select: {
    up: "select.previous",
    down: "select.next",
    return: "select.confirm",
    escape: "select.close",
  },
  contextMenu: {
    "up, k": "contextMenu.previous",
    "down, j": "contextMenu.next",
    return: "contextMenu.run",
    escape: "contextMenu.close",
  },
  rename: { escape: "overlay.cancel" },
  join: { escape: "cluster.join.cancel" },
  ask: { escape: "ask.cancel" },
  leader: LEADER_LAYER,
  imagePreview: { escape: "image.close" },
  confirmDelete: { y: "thread.delete.confirm", "n, escape": "overlay.cancel" },
  diff: {
    up: "diff.previous",
    down: "diff.next",
    pageup: "diff.scrollUp",
    pagedown: "diff.scrollDown",
    s: "diff.toggleView",
    r: "diff.refresh",
    "escape, ctrl+p": "diff.close",
  },
  files: {
    up: "files.previous",
    down: "files.next",
    pageup: "files.scrollUp",
    pagedown: "files.scrollDown",
    "return, right": "files.activate",
    "left, backspace": "files.up",
    e: "files.edit",
    r: "files.refresh",
    escape: "files.back",
    "ctrl+p": "rightPanel.blur",
  },
  settings: {
    "up, pageup": "settings.scrollUp",
    "down, pagedown": "settings.scrollDown",
    "escape, ctrl+p": "settings.close",
    r: "keymap.rebind.open",
  },
  /** A settings page: its rows, then its one-line field and its yes / no question. */
  section: {
    "up, k": "section.previous",
    "down, j": "section.next",
    return: "section.activate",
    escape: "section.back",
    "ctrl+p": "section.close",
    "ctrl+k": "palette.open",
  },
  sectionInput: { escape: "section.input.cancel" },
  sectionConfirm: { y: "section.confirm.yes", "n, escape": "section.confirm.no" },
  panel: {
    up: "rightPanel.previous",
    down: "rightPanel.next",
    return: "rightPanel.activate",
    "escape, ctrl+p": "rightPanel.blur",
    "ctrl+l": "rightPanel.toggle",
    x: "git.log.dismiss",
  },
  commit: { escape: "git.commit.cancel", "ctrl+p": "rightPanel.blur" },
  project: {
    up: "project.add.previous",
    down: "project.add.next",
    tab: "project.add.toggleFocus",
    return: "project.add.activate",
    "ctrl+return": "project.add.action",
    escape: "project.add.back",
  },
  filter: {
    return: "sidebar.filter.commit",
    escape: "sidebar.filter.cancel",
  },
  /**
   * The thread list with the keys (`Keymap { name: "list" }`, so a keymap.json
   * "list" section overrides it). Its actions are the list's own names; one
   * chord per entry so a `"j": null` override frees just that key.
   */
  list: { j: "next", down: "next", k: "previous", up: "previous", escape: "leave" },
} satisfies Record<string, KeymapLayer>;

/** Every chord the layers bind, split into single chords ("up, k" → "up", "k"). */
export function boundChords(layers: Record<string, KeymapLayer> = KEYMAP_LAYERS): string[] {
  const chords = new Set<string>();
  for (const layer of Object.values(layers)) {
    for (const chord of Object.keys(layer)) {
      for (const part of chord.split(",")) chords.add(part.trim());
    }
  }
  return [...chords];
}

const splitChords = (chords: string): string[] => chords.split(",").map((part) => part.trim());

const KEY_NAMES: Record<string, string> = {
  esc: "escape",
  enter: "return",
  pgup: "pageup",
  pgdn: "pagedown",
  del: "delete",
};
const MODIFIERS = ["ctrl", "alt", "shift"];

/** "Ctrl+T" or "^t" as a Keymap chord ("ctrl+t"); null when it names no key. */
export function normalizeChord(text: string): string | null {
  const spelled = text.trim().toLowerCase().replace(/^\^/, "ctrl+").replace(/\s+/g, "");
  if (spelled === "") return null;
  const parts = spelled.split("+");
  const key = parts.pop() ?? "";
  if (key === "" || MODIFIERS.includes(key)) return null;
  const modifiers = parts.map((part) =>
    part === "control" ? "ctrl" : part === "meta" ? "alt" : part,
  );
  if (modifiers.some((part) => !MODIFIERS.includes(part))) return null;
  return [...MODIFIERS.filter((part) => modifiers.includes(part)), KEY_NAMES[key] ?? key].join("+");
}

/** A chord as the client spells it for the user: "ctrl+shift+m" → "Ctrl+Shift+M". */
export function chordLabel(chords: string): string {
  return splitChords(chords)
    .map((chord) =>
      chord
        .split("+")
        .map((part) =>
          part.length === 1 ? part.toUpperCase() : part[0]!.toUpperCase() + part.slice(1),
        )
        .join("+"),
    )
    .join(" / ");
}

// The reference group that documents each mode's chords first.
const MODE_GROUP: Record<string, string> = {
  terminal: "Terminal",
  panel: "Source control",
  commit: "Source control",
  compose: "Conversation",
  newThread: "Conversation",
  userInput: "Conversation",
};

/** What the reference says a chord does in `mode`; the action's name when it is undocumented. */
export function describeChord(chords: string, action: string, mode: string): string {
  const first = splitChords(chords)[0]!;
  const preferred = MODE_GROUP[mode] ?? "Overlays (palette / diff / files / pickers)";
  const ordered = [
    ...KEYBINDING_GROUPS.filter((group) => group.title === preferred),
    ...KEYBINDING_GROUPS.filter((group) => group.title === "Global"),
    ...KEYBINDING_GROUPS.filter((group) => group.title !== preferred && group.title !== "Global"),
  ];
  for (const group of ordered) {
    const binding = group.bindings.find((candidate) => candidate.chords?.includes(first));
    if (binding) return binding.description;
  }
  return action;
}

/** What the reference says `action` does in `mode`, by the chord it has by default. */
export function describeAction(action: string, mode: string): string {
  const layers: Record<string, KeymapLayer> = KEYMAP_LAYERS;
  for (const layer of [layers[mode] ?? {}, layers.global ?? {}]) {
    const chord = Object.keys(layer).find((candidate) => layer[candidate] === action);
    if (chord !== undefined) return describeChord(chord, action, mode);
  }
  return action;
}

/**
 * Give `action` the chord `chord` in every layer that binds it, in place of
 * the chords it had there (`freed`, for the layers the prompt uses).
 */
export function rebindLayers(
  layers: Record<string, KeymapLayer>,
  action: string,
  chord: string,
): { readonly layers: Record<string, KeymapLayer>; readonly freed: string[] } {
  const freed = new Set<string>();
  const next: Record<string, KeymapLayer> = {};
  for (const [name, layer] of Object.entries(layers)) {
    const bound = Object.entries(layer).filter(([, candidate]) => candidate === action);
    if (bound.length === 0) {
      next[name] = layer;
      continue;
    }
    for (const [old] of bound) for (const part of splitChords(old)) freed.add(part);
    next[name] = {
      ...Object.fromEntries(Object.entries(layer).filter(([, candidate]) => candidate !== action)),
      [chord]: action,
    };
  }
  freed.delete(chord);
  return { layers: next, freed: [...freed] };
}

/**
 * Check a user's keymap.json (chord → action, null unbinds). Two entries
 * that spell the same chord for different actions ("ctrl+t" and "Ctrl+T")
 * conflict: JSON would let the later one win silently, so both are dropped
 * (each action keeps its default chord) and the conflict is reported.
 * Sections for named keymaps (`{ "list": { … } }`) pass through.
 */
export function resolveKeymapFile(file: Record<string, unknown>): {
  readonly keymap: Record<string, unknown>;
  readonly conflicts: string[];
} {
  const actionsByChord = new Map<string, Set<string>>();
  const chordsOf = (key: string) => splitChords(key).map((part) => normalizeChord(part) ?? part);
  for (const [key, value] of Object.entries(file)) {
    if (typeof value !== "string") continue;
    for (const chord of chordsOf(key)) {
      actionsByChord.set(chord, (actionsByChord.get(chord) ?? new Set()).add(value));
    }
  }
  const contested = [...actionsByChord].filter(([, actions]) => actions.size > 1);
  const keymap: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(file)) {
    if (typeof value !== "string" && value !== null) {
      keymap[key] = value;
      continue;
    }
    // Spelled the engine's way ("ctrl+t"), so "Ctrl+T" binds too.
    const chords = chordsOf(key);
    if (chords.some((chord) => contested.some(([taken]) => taken === chord))) continue;
    keymap[chords.join(", ")] = value;
  }
  return {
    keymap,
    conflicts: contested.map(
      ([chord, actions]) =>
        `keymap.json binds ${chordLabel(chord)} to ${[...actions]
          .map((action) => `"${action}"`)
          .join(" and ")}; neither is applied`,
    ),
  };
}

/** How the terminal lines up with the web app's keybindings (the parity table). */
export interface KeymapParityRow {
  readonly action: string;
  readonly webKeys: string;
  /** The terminal chords, as the reference shows them. */
  readonly keys: string;
  /** The host action the chords dispatch. */
  readonly hostAction: string;
  readonly chords: ReadonlyArray<string>;
  readonly status: "aligned" | "divergent";
}

export const KEYMAP_PARITY: ReadonlyArray<KeymapParityRow> = [
  {
    action: "plan/build toggle",
    webKeys: "Shift+Tab",
    keys: "Shift+Tab or Ctrl+B",
    hostAction: "composer.interactionMode.toggle",
    chords: ["shift+tab", "ctrl+b"],
    status: "aligned",
  },
  {
    action: "new thread",
    webKeys: "Cmd/Ctrl+N",
    keys: "Ctrl+N",
    hostAction: "thread.new",
    chords: ["ctrl+n"],
    status: "aligned",
  },
  {
    action: "toggle terminal",
    webKeys: "Ctrl+`",
    keys: "Ctrl+E",
    hostAction: "terminal.toggle",
    chords: ["ctrl+e"],
    status: "aligned",
  },
  {
    action: "command palette",
    webKeys: "Cmd/Ctrl+K",
    keys: "Ctrl+K",
    hostAction: "palette.open",
    chords: ["ctrl+k"],
    status: "aligned",
  },
  {
    action: "filter / search",
    webKeys: "Cmd/Ctrl+F",
    keys: "Ctrl+F",
    hostAction: "sidebar.filter.focus",
    chords: ["ctrl+f"],
    status: "aligned",
  },
  {
    action: "source-control panel",
    webKeys: "a visible surface",
    keys: "Ctrl+L",
    hostAction: "rightPanel.toggle",
    chords: ["ctrl+l"],
    status: "aligned",
  },
  {
    action: "thread next/prev",
    webKeys: "Cmd/Ctrl+[ and ]",
    keys: "Alt+Up and Alt+Down",
    hostAction: "thread.next",
    chords: ["alt+down", "alt+up"],
    status: "aligned",
  },
  {
    action: "thread jump 1-9",
    webKeys: "Cmd/Ctrl+1 to 9",
    keys: "Alt+1 to Alt+9",
    hostAction: "thread.jump.1",
    chords: ["alt+1", "alt+9"],
    status: "aligned",
  },
];
