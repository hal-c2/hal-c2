import { describe, expect, it } from "vite-plus/test";
import {
  compileResolvedKeybindingsConfig,
  parseKeybindingShortcut,
} from "@hal-c2/shared/keybindings";

import {
  buildShellKeybindings,
  buildShellModelPickerKeys,
  shellKeybindingPressToForward,
  toShellKeybinding,
} from "./shellKeybindings";

function shortcut(value: string) {
  const parsed = parseKeybindingShortcut(value);
  if (parsed === null) throw new Error(`unparseable shortcut ${value}`);
  return parsed;
}

describe("toShellKeybinding", () => {
  it("maps mod to Ctrl on Linux and replays it as ctrlKey", () => {
    expect(toShellKeybinding(shortcut("mod+shift+]"), "Linux x86_64")).toEqual({
      sequence: "Ctrl+Shift+]",
      key: "]",
      ctrlKey: true,
      metaKey: false,
      shiftKey: true,
      altKey: false,
    });
  });

  it("maps mod to Command on macOS, which Qt spells Ctrl", () => {
    expect(toShellKeybinding(shortcut("mod+b"), "MacIntel")).toMatchObject({
      sequence: "Ctrl+B",
      metaKey: true,
      ctrlKey: false,
    });
    expect(toShellKeybinding(shortcut("ctrl+k"), "MacIntel")).toMatchObject({
      sequence: "Meta+K",
      metaKey: false,
      ctrlKey: true,
    });
  });

  it("names special keys the way QKeySequence expects", () => {
    expect(toShellKeybinding(shortcut("mod+arrowdown"), "Linux")?.sequence).toBe("Ctrl+Down");
    expect(toShellKeybinding(shortcut("alt+space"), "Linux")?.sequence).toBe("Alt+Space");
    expect(toShellKeybinding(shortcut("mod+f5"), "Linux")?.sequence).toBe("Ctrl+F5");
    expect(toShellKeybinding(shortcut("mod++"), "Linux")?.sequence).toBe("Ctrl++");
  });

  it("leaves unmodified and unnameable keys to the native control", () => {
    expect(toShellKeybinding(shortcut("escape"), "Linux")).toBeNull();
    expect(toShellKeybinding(shortcut("shift+enter"), "Linux")).toBeNull();
    expect(toShellKeybinding(shortcut("mod+mediaplay"), "Linux")).toBeNull();
  });
});

describe("buildShellKeybindings", () => {
  it("publishes each sequence once regardless of how many rules share it", () => {
    const config = compileResolvedKeybindingsConfig([
      { key: "mod+d", command: "terminal.split", when: "terminalFocus" },
      { key: "mod+d", command: "diff.toggle", when: "!terminalFocus" },
      { key: "mod+shift+m", command: "modelPicker.toggle" },
      { key: "escape", command: "commandPalette.toggle" },
    ]);
    expect(buildShellKeybindings(config, "Linux").map((binding) => binding.sequence)).toEqual([
      "Ctrl+D",
      "Ctrl+Shift+M",
    ]);
  });
});

describe("shellKeybindingPressToForward", () => {
  const config = compileResolvedKeybindingsConfig([
    { key: "mod+1", command: "thread.jump.1" },
    { key: "mod+b", command: "sidebar.toggle" },
    { key: "mod+d", command: "diff.toggle", when: "!terminalFocus" },
    { key: "mod+d", command: "terminal.split", when: "terminalFocus" },
    { key: "mod+w", command: "terminal.close", when: "terminalFocus" },
  ]);
  const ctrl = (key: string) => ({
    key,
    ctrlKey: true,
    metaKey: false,
    shiftKey: false,
    altKey: false,
  });

  it("forwards a chord the primary resolves to the same command", () => {
    expect(
      shellKeybindingPressToForward(ctrl("1"), config, "Linux", { terminalFocus: true }),
    ).toEqual(ctrl("1"));
    expect(
      shellKeybindingPressToForward(ctrl("b"), config, "Linux", { terminalFocus: true }),
    ).toEqual(ctrl("b"));
  });

  it("keeps a chord whose command depends on the embed's focus", () => {
    expect(
      shellKeybindingPressToForward(ctrl("d"), config, "Linux", { terminalFocus: true }),
    ).toBeNull();
    expect(
      shellKeybindingPressToForward(ctrl("w"), config, "Linux", { terminalFocus: true }),
    ).toBeNull();
  });

  it("normalizes shifted letter and named keys before crossing the shell contract", () => {
    const shifted = compileResolvedKeybindingsConfig([
      { key: "mod+shift+b", command: "sidebar.toggle" },
      { key: "mod+arrowdown", command: "thread.jump.1" },
    ]);
    expect(
      shellKeybindingPressToForward({ ...ctrl("B"), shiftKey: true }, shifted, "Linux", {}),
    ).toEqual({ ...ctrl("b"), shiftKey: true });
    expect(shellKeybindingPressToForward(ctrl("ArrowDown"), shifted, "Linux", {})).toEqual(
      ctrl("arrowdown"),
    );
  });

  it("ignores keys bound to nothing", () => {
    expect(shellKeybindingPressToForward(ctrl("z"), config, "Linux", {})).toBeNull();
  });
});

describe("buildShellModelPickerKeys", () => {
  it("resolves the open picker's chords with the web's labels", () => {
    const config = compileResolvedKeybindingsConfig([
      { key: "mod+shift+m", command: "modelPicker.toggle" },
      {
        key: "mod+shift+arrowup",
        command: "modelPicker.previousProvider",
        when: "modelPickerOpen",
      },
      { key: "mod+shift+arrowdown", command: "modelPicker.nextProvider", when: "modelPickerOpen" },
      { key: "mod+1", command: "thread.jump.1" },
      { key: "mod+1", command: "modelPicker.jump.1", when: "modelPickerOpen" },
      { key: "mod+2", command: "modelPicker.jump.2", when: "modelPickerOpen" },
    ]);
    const keys = buildShellModelPickerKeys(config, "Linux x86_64");
    expect(keys.shortcut).toBe("Ctrl+Shift+M");
    expect(keys.nextProvider).toEqual({
      key: "arrowdown",
      ctrlKey: true,
      metaKey: false,
      shiftKey: true,
      altKey: false,
      label: "Ctrl+Shift+Down",
    });
    expect(keys.jump).toHaveLength(9);
    expect(keys.jump.slice(0, 3).map((key) => key?.label ?? null)).toEqual([
      "Ctrl+1",
      "Ctrl+2",
      null,
    ]);
  });

  it("uses Command for mod on macOS", () => {
    const config = compileResolvedKeybindingsConfig([
      { key: "mod+1", command: "modelPicker.jump.1", when: "modelPickerOpen" },
    ]);
    expect(buildShellModelPickerKeys(config, "MacIntel").jump[0]).toMatchObject({
      metaKey: true,
      ctrlKey: false,
      label: "\u23181",
    });
  });
});
