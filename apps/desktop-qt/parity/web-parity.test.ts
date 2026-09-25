// @effect-diagnostics nodeBuiltinImport:off - Plain evidence checks against files in the repository.
import * as NodeFSP from "node:fs/promises";

import { describe, expect, it } from "vite-plus/test";

// Web keymap ⇄ Qt shell parity. The shell hosts the web app, so most chords
// are the page's own: `apps/web/src/shell/shellKeybindings.ts` publishes every
// modified chord, `ShellWindow.qml` registers a window Shortcut per chord while
// native chrome has focus, and the page replays the press as
// `keybinding.press` on `document.body`. Such rows are aligned and say so in
// the `qt` column. A replay on the body carries no composer or picker focus, so
// chords scoped to those, and keys the native composer does not handle itself,
// are backlog. Whole unported capabilities live in features.backlog.test.ts.

// "aligned" = the key does the web thing in the shell; "backlog" = a web chord
// that is dead or different in the shell today; "n/a" = the web chord targets
// HTML the shell replaces with a native control that has its own keys.
type ParityStatus = "aligned" | "backlog" | "n/a";
interface KeyParity {
  /** A keybinding command from DEFAULT_KEYBINDINGS, or a description for a key the page handles locally. */
  readonly command: string;
  /** The web default, in keybinding config syntax. */
  readonly web: string;
  readonly qt: string | null;
  readonly status: ParityStatus;
  /** Why a row is not aligned, and where the fix belongs. */
  readonly note?: string;
}

const FORWARDED = "forwarded as keybinding.press";

const KEYMAP_PARITY: ReadonlyArray<KeyParity> = [
  { command: "chat.new", web: "mod+n", qt: `Mod+N, ${FORWARDED}`, status: "aligned" },
  {
    command: "chat.newLocal",
    web: "mod+shift+n",
    qt: `Mod+Shift+N, ${FORWARDED}`,
    status: "aligned",
  },
  {
    command: "commandPalette.toggle",
    web: "mod+k",
    qt: `Mod+K, ${FORWARDED}`,
    status: "aligned",
  },
  {
    command: "terminal.toggle",
    web: "mod+j",
    qt: `Mod+J, ${FORWARDED}; the Workspace terminal button`,
    status: "aligned",
  },
  {
    command: "sidebar.toggle",
    web: "mod+b",
    qt: `Mod+B, ${FORWARDED}; the native sidebar buttons`,
    status: "aligned",
  },
  {
    command: "rightPanel.toggle",
    web: "mod+alt+b",
    qt: `Mod+Alt+B, ${FORWARDED}`,
    status: "aligned",
  },
  { command: "diff.toggle", web: "mod+d", qt: `Mod+D, ${FORWARDED}`, status: "aligned" },
  {
    command: "terminal.split",
    web: "mod+d",
    qt: "Mod+D, handled by the terminal drawer's own document",
    status: "aligned",
  },
  { command: "navigation.back", web: "mod+[", qt: `Mod+[, ${FORWARDED}`, status: "aligned" },
  { command: "navigation.forward", web: "mod+]", qt: `Mod+], ${FORWARDED}`, status: "aligned" },
  {
    command: "thread.previous",
    web: "mod+shift+[",
    qt: `Mod+Shift+[, ${FORWARDED}`,
    status: "aligned",
  },
  {
    command: "thread.next",
    web: "mod+shift+]",
    qt: `Mod+Shift+], ${FORWARDED}`,
    status: "aligned",
  },
  { command: "filePicker.toggle", web: "mod+p", qt: `Mod+P, ${FORWARDED}`, status: "aligned" },
  {
    command: "projectSearch.toggle",
    web: "mod+shift+f",
    qt: `Mod+Shift+F, ${FORWARDED}`,
    status: "aligned",
  },
  { command: "theme.select", web: "mod+alt+a", qt: `Mod+Alt+A, ${FORWARDED}`, status: "aligned" },
  {
    command: "modelPicker.toggle",
    web: "mod+shift+m",
    qt: `Mod+Shift+M, ${FORWARDED}; the page toggles the native picker via composer.modelPicker.toggle`,
    status: "aligned",
  },
  { command: "editor.openFavorite", web: "mod+o", qt: `Mod+O, ${FORWARDED}`, status: "aligned" },
  {
    command: "thread.copyReference",
    web: "mod+shift+c",
    qt: `Mod+Shift+C, ${FORWARDED}`,
    status: "aligned",
  },
  {
    command: "thread.settle",
    web: "mod+shift+s",
    qt: `Mod+Shift+S, ${FORWARDED}`,
    status: "aligned",
  },
  { command: "thread.pin", web: "mod+shift+p", qt: `Mod+Shift+P, ${FORWARDED}`, status: "aligned" },
  {
    command: "thread jump 1–9",
    web: "mod+1…9",
    qt: null,
    status: "backlog",
    note: 'The defaults are gated on `when: "isDesktop"`, which is Electron-only, so the forwarded press matches nothing.',
  },
  {
    command: "plan/build toggle",
    web: "shift+tab",
    qt: null,
    status: "backlog",
    note: "The web composer handles Shift+Tab itself; the native composer does not.",
  },
  {
    command: "prompt history",
    web: "arrowup",
    qt: null,
    status: "backlog",
    note: "The web composer recalls earlier prompts on Up in an empty editor; the native composer does not.",
  },
  {
    command: "composer.sendAlternate",
    web: "mod+enter",
    qt: null,
    status: "backlog",
    note: "The window Shortcut takes Ctrl+Return from the native composer and the body replay has no composerFocus.",
  },
  {
    command: "composer.sendBackground",
    web: "mod+alt+enter",
    qt: null,
    status: "backlog",
    note: "The window Shortcut takes Ctrl+Alt+Return from the native composer and the body replay has no composerFocus.",
  },
  {
    command: "thread.editQueuedMessage",
    web: "alt+arrowup",
    qt: null,
    status: "backlog",
    note: "Scoped to composerFocus, which the body replay never has.",
  },
  ...(
    [
      ["composer.effort", "mod+shift+e"],
      ["composer.mode", "mod+shift+a"],
      ["composer.host", "mod+shift+h"],
      ["composer.workspace", "mod+shift+x"],
      ["composer.branch", "mod+shift+g"],
      ["composer.previousWorktree", "mod+shift+l"],
    ] as const
  ).map(([command, web]) => ({
    command,
    web,
    qt: null,
    status: "backlog" as const,
    note: "The page opens a control on its own composer toolbar or branch strip, which it does not render under the shell.",
  })),
  {
    command: "preview.toggle",
    web: "mod+shift+j",
    qt: null,
    status: "backlog",
    note: "Needs the in-app-preview gap in features.backlog.test.ts.",
  },
  {
    command: "modelPicker.previousProvider",
    web: "mod+shift+arrowup",
    qt: null,
    status: "n/a",
    note: "Scoped to the HTML model picker; the shell's native picker is a combo box with its own arrow keys.",
  },
  {
    command: "modelPicker.nextProvider",
    web: "mod+shift+arrowdown",
    qt: null,
    status: "n/a",
    note: "Scoped to the HTML model picker; the shell's native picker is a combo box with its own arrow keys.",
  },
];

const REPOSITORY_ROOT = new URL("../../../", import.meta.url);
const WEB_KEYBINDINGS_SOURCE = "packages/shared/src/keybindings.ts";

/** Reads the (key, command, when) rules written literally in DEFAULT_KEYBINDINGS. */
async function readDefaultRules() {
  const source = await NodeFSP.readFile(new URL(WEB_KEYBINDINGS_SOURCE, REPOSITORY_ROOT), "utf8");
  const start = source.indexOf("export const DEFAULT_KEYBINDINGS");
  expect(start, "DEFAULT_KEYBINDINGS").toBeGreaterThanOrEqual(0);
  const body = source.slice(start, source.indexOf("];", start));
  const rules = [
    ...body.matchAll(
      /\{\s*key:\s*"([^"]+)",\s*command:\s*"([^"]+)"(?:,\s*when:\s*"([^"]+)")?,?\s*\}/g,
    ),
  ].map(([, key, command, when]) => ({ key, command, when }));
  return { body, rules };
}

const isConfigCommand = (entry: KeyParity) => entry.command.includes(".");
const row = (command: string) => KEYMAP_PARITY.find((entry) => entry.command === command);

describe("Qt shell keyboard parity", () => {
  it("Given the keymap table, when it is validated, then every row is unique and coherent", () => {
    const commands = KEYMAP_PARITY.map((entry) => entry.command);
    expect(new Set(commands).size).toBe(commands.length);

    for (const entry of KEYMAP_PARITY) {
      expect(entry.web.length, entry.command).toBeGreaterThan(0);
      if (entry.status === "aligned") {
        expect(entry.qt, entry.command).not.toBeNull();
        expect((entry.qt ?? "").trim().length, entry.command).toBeGreaterThan(0);
      } else {
        expect(entry.qt, entry.command).toBeNull();
        expect((entry.note ?? "").trim().length, `${entry.command} note`).toBeGreaterThan(0);
      }
    }
  });

  it("Given the web defaults, when the table names a keybinding command, then that chord is still bound to it", async () => {
    const { rules } = await readDefaultRules();
    for (const entry of KEYMAP_PARITY.filter(isConfigCommand)) {
      expect(
        rules.some((rule) => rule.key === entry.web && rule.command === entry.command),
        `${entry.web} → ${entry.command} in ${WEB_KEYBINDINGS_SOURCE}`,
      ).toBe(true);
    }
  });

  it("Given the web's thread jump defaults, when the shell forwards Mod+1…9, then they stay backlog while gated on isDesktop", async () => {
    const { body } = await readDefaultRules();
    expect(body).toMatch(
      /THREAD_JUMP_KEYBINDING_COMMANDS\.map\([^)]*\)\s*=>\s*\(\{\s*key:\s*`mod\+\$\{index \+ 1\}`,\s*command,\s*when:\s*"isDesktop"/,
    );
    expect(row("thread jump 1–9")?.status).toBe("backlog");
  });

  it("Given the headline web chords, when they are pressed from native chrome, then new thread, palette, terminal, sidebar and thread stepping are forwarded", () => {
    for (const command of [
      "chat.new",
      "commandPalette.toggle",
      "terminal.toggle",
      "sidebar.toggle",
      "thread.previous",
      "thread.next",
    ]) {
      expect(row(command)?.status, command).toBe("aligned");
      expect(row(command)?.qt, command).toContain(FORWARDED);
    }
  });

  it("Given the web's plan/build and prompt history keys, when the native composer has focus, then they are tracked as backlog", () => {
    expect(row("plan/build toggle")).toMatchObject({ web: "shift+tab", status: "backlog" });
    expect(row("prompt history")).toMatchObject({ web: "arrowup", status: "backlog" });
  });
});
