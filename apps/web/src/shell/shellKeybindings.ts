import type {
  KeybindingCommand,
  KeybindingShortcut,
  ResolvedKeybindingsConfig,
} from "@hal-c2/contracts";
import type {
  ShellKeybinding,
  ShellKeybindingsState,
  ShellModelPickerKey,
  ShellModelPickerState,
} from "@hal-c2/contracts/shell";

import { isMacPlatform } from "../lib/utils";
import {
  findEffectiveShortcutForCommand,
  formatShortcutLabel,
  modelPickerJumpCommandForIndex,
  resolveShortcutCommand,
  shortcutLabelForCommand,
  type ShortcutEventLike,
  type ShortcutMatchContext,
} from "../keybindings";

/** Web `event.key` names (lowercased by the parser) → portable QKeySequence names. */
const QT_KEY_NAMES: Readonly<Record<string, string>> = {
  " ": "Space",
  arrowdown: "Down",
  arrowleft: "Left",
  arrowright: "Right",
  arrowup: "Up",
  backspace: "Backspace",
  delete: "Del",
  end: "End",
  enter: "Return",
  escape: "Esc",
  home: "Home",
  insert: "Ins",
  pagedown: "PgDown",
  pageup: "PgUp",
  tab: "Tab",
};

function qtKeyName(key: string): string | null {
  const named = QT_KEY_NAMES[key];
  if (named !== undefined) return named;
  if (/^f([1-9]|1\d|2[0-4])$/.test(key)) return key.toUpperCase();
  if (key.length === 1) return key.toUpperCase();
  return null;
}

/**
 * One page shortcut as the shell should register it, or null when the shell
 * must leave it alone: unmodified keys belong to whichever native control has
 * focus, and a key Qt has no name for cannot be registered at all.
 */
export function toShellKeybinding(
  shortcut: KeybindingShortcut,
  platform: string,
): ShellKeybinding | null {
  const mac = isMacPlatform(platform);
  const metaKey = shortcut.metaKey || (shortcut.modKey && mac);
  const ctrlKey = shortcut.ctrlKey || (shortcut.modKey && !mac);
  if (!metaKey && !ctrlKey && !shortcut.altKey) return null;
  const keyName = qtKeyName(shortcut.key);
  if (keyName === null) return null;
  // Qt's portable names are swapped on macOS: "Ctrl" is Command, "Meta" is Control.
  const parts: string[] = [];
  if (mac ? metaKey : ctrlKey) parts.push("Ctrl");
  if (mac ? ctrlKey : metaKey) parts.push("Meta");
  if (shortcut.altKey) parts.push("Alt");
  if (shortcut.shiftKey) parts.push("Shift");
  parts.push(keyName);
  return {
    sequence: parts.join("+"),
    key: shortcut.key,
    ctrlKey,
    metaKey,
    shiftKey: shortcut.shiftKey,
    altKey: shortcut.altKey,
  };
}

/**
 * Every distinct sequence the page listens for. Rules that share a sequence
 * (terminal vs. chat variants of the same chord) collapse to one entry: the
 * page resolves the command, with its `when` clauses, once the key is
 * replayed.
 */
export function buildShellKeybindings(
  config: ResolvedKeybindingsConfig,
  platform: string,
): ShellKeybindingsState {
  const seen = new Set<string>();
  const result: ShellKeybinding[] = [];
  for (const rule of config) {
    const binding = toShellKeybinding(rule.shortcut, platform);
    if (binding === null || seen.has(binding.sequence)) continue;
    seen.add(binding.sequence);
    result.push(binding);
  }
  return result;
}

export type ShellKeybindingPress = Omit<ShellKeybinding, "sequence">;

/**
 * The `keybinding.press` a secondary document forwards for a keydown it
 * received, or null when the key is not the primary's to act on. The primary
 * replays a press on its body, that is with nothing focused, so only a chord
 * that resolves to the same command with the embed's focus context and
 * without one is forwarded: `mod+1` jumps threads either way, while `mod+d`
 * splits the focused terminal here and would toggle the diff there.
 */
export function shellKeybindingPressToForward(
  event: ShortcutEventLike,
  config: ResolvedKeybindingsConfig,
  platform: string,
  context: Partial<ShortcutMatchContext>,
): ShellKeybindingPress | null {
  const command = resolveShortcutCommand(event, config, { platform, context });
  if (command === null) return null;
  if (resolveShortcutCommand(event, config, { platform }) !== command) return null;
  return {
    key: event.key.toLowerCase(),
    ctrlKey: event.ctrlKey,
    metaKey: event.metaKey,
    shiftKey: event.shiftKey,
    altKey: event.altKey,
  };
}

const MODEL_PICKER_OPEN_CONTEXT = {
  terminalFocus: false,
  terminalOpen: false,
  modelPickerOpen: true,
} as const;

/**
 * The chords the native model picker handles while it is open, resolved as
 * the web picker resolves them, so custom bindings carry over.
 */
export function buildShellModelPickerKeys(
  config: ResolvedKeybindingsConfig,
  platform: string,
): Pick<ShellModelPickerState, "shortcut" | "previousProvider" | "nextProvider" | "jump"> {
  const mac = isMacPlatform(platform);
  const resolve = (command: KeybindingCommand): ShellModelPickerKey | null => {
    const shortcut = findEffectiveShortcutForCommand(config, command, {
      platform,
      context: MODEL_PICKER_OPEN_CONTEXT,
    });
    if (shortcut === null) return null;
    return {
      key: shortcut.key,
      ctrlKey: shortcut.ctrlKey || (shortcut.modKey && !mac),
      metaKey: shortcut.metaKey || (shortcut.modKey && mac),
      shiftKey: shortcut.shiftKey,
      altKey: shortcut.altKey,
      label: formatShortcutLabel(shortcut, platform),
    };
  };
  const jump: Array<ShellModelPickerKey | null> = [];
  for (let index = 0; ; index += 1) {
    const command = modelPickerJumpCommandForIndex(index);
    if (command === null) break;
    jump.push(resolve(command));
  }
  return {
    shortcut: shortcutLabelForCommand(config, "modelPicker.toggle", platform),
    previousProvider: resolve("modelPicker.previousProvider"),
    nextProvider: resolve("modelPicker.nextProvider"),
    jump,
  };
}
