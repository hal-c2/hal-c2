import { DEFAULT_RESOLVED_KEYBINDINGS } from "@hal-c2/shared/keybindings";
import { afterEach, assert, it, vi } from "vite-plus/test";

afterEach(() => {
  vi.unstubAllGlobals();
  vi.resetModules();
});

async function commandForModThree() {
  const { resolveShortcutCommand } = await import("./keybindings");
  return resolveShortcutCommand(
    { key: "3", ctrlKey: true, metaKey: false, shiftKey: false, altKey: false },
    DEFAULT_RESOLVED_KEYBINDINGS,
    { platform: "Linux x86_64" },
  );
}

it("Given the Qt shell hosts the page, when mod+3 is pressed, then it jumps to the third thread", async () => {
  vi.stubGlobal("window", { halC2Shell: { surfaceId: "primary" } });
  assert.strictEqual(await commandForModThree(), "thread.jump.3");
});

it("Given a browser tab, when mod+3 is pressed, then the browser keeps it", async () => {
  vi.stubGlobal("window", {});
  assert.isNull(await commandForModThree());
});
