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
      { keys: "^U", description: "Reopen a pending question", chords: ["ctrl+u"] },
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
    ],
  },
  {
    title: "Overlays (palette / diff / files / pickers)",
    bindings: [
      { keys: "↑/↓ · j/k", description: "Move the selection", chords: ["up", "down", "j", "k"] },
      { keys: "Enter", description: "Run / open / apply", chords: ["return"] },
      {
        keys: "PgUp/PgDn",
        description: "Scroll a file, diff or settings",
        chords: ["pageup", "pagedown"],
      },
      { keys: "Esc", description: "Back / close", chords: ["escape"] },
      { keys: "^P", description: "Back to the prompt from any pane", chords: ["ctrl+p"] },
      { keys: "s", description: "Diff: toggle split / stacked", chords: ["s"] },
    ],
  },
];

/** Chord → host action, per input mode (`Shell.state.mode`). */
export type KeymapLayer = Readonly<Record<string, string>>;

const THREAD_JUMPS: KeymapLayer = Object.fromEntries(
  Array.from({ length: 9 }, (_, index) => [`alt+${index + 1}`, `thread.jump.${index + 1}`]),
);

/**
 * The chords each mode binds. Plain printable and editing keys (including
 * Enter) reach a focused prompt or field first; the prompt sends on Enter
 * itself. Modes whose owner handles every key (the question form, the rename
 * and commit fields, the delete confirmation) have no layer here.
 */
export const KEYMAP_LAYERS = {
  /** Everywhere but the terminal drawer, which passes ^C to the shell. */
  global: { "ctrl+c": "app.quit", "ctrl+p": "composer.focus" },
  compose: {
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
    "ctrl+u": "userInput.reopen",
    escape: "composer.escape",
    return: "composer.submit",
  },
  terminal: {
    "ctrl+e": "terminal.toggle",
    "ctrl+p": "composer.focus",
    "ctrl+up": "terminal.grow",
    "ctrl+down": "terminal.shrink",
    "ctrl+o": "terminal.copy",
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
  diff: {
    up: "diff.previous",
    down: "diff.next",
    pageup: "diff.scrollUp",
    pagedown: "diff.scrollDown",
    s: "diff.toggleView",
    escape: "diff.close",
  },
  files: {
    up: "files.previous",
    down: "files.next",
    pageup: "files.scrollUp",
    pagedown: "files.scrollDown",
    return: "files.open",
    escape: "files.back",
  },
  settings: {
    "up, pageup": "settings.scrollUp",
    "down, pagedown": "settings.scrollDown",
    escape: "settings.close",
  },
  panel: {
    up: "rightPanel.previous",
    down: "rightPanel.next",
    return: "rightPanel.activate",
    escape: "rightPanel.blur",
    "ctrl+l": "rightPanel.toggle",
  },
  filter: {
    return: "sidebar.filter.commit",
    escape: "sidebar.filter.cancel",
  },
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
