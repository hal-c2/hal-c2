import { describe, expect, it } from "bun:test";

import { inlineImageTransport, isKnownKittyGraphicsTerminal } from "./terminalGraphics.ts";

describe("Kitty graphics terminal detection", () => {
  it("recognizes direct Ghostty, Kitty, WezTerm, and Konsole markers", () => {
    expect(isKnownKittyGraphicsTerminal({ TERM: "xterm-ghostty" })).toBe(true);
    expect(isKnownKittyGraphicsTerminal({ KITTY_WINDOW_ID: "1" })).toBe(true);
    expect(isKnownKittyGraphicsTerminal({ WEZTERM_PANE: "2" })).toBe(true);
    expect(isKnownKittyGraphicsTerminal({ KONSOLE_VERSION: "250400" })).toBe(true);
  });

  it("uses tmux's saved outer environment when the pane identifies only as tmux", () => {
    expect(
      isKnownKittyGraphicsTerminal(
        { TERM: "tmux-256color", TERM_PROGRAM: "tmux" },
        "TERM=xterm-ghostty\nTERM_PROGRAM=ghostty\n",
      ),
    ).toBe(true);
  });

  it("does not opt an unknown tmux client into Kitty graphics", () => {
    expect(
      isKnownKittyGraphicsTerminal(
        { TERM: "tmux-256color", TERM_PROGRAM: "tmux" },
        "TERM=xterm-256color\nTERM_PROGRAM=Alacritty\n",
      ),
    ).toBe(false);
  });
});

describe("inline image transport", () => {
  it("draws straight to a known terminal and not at all to an unknown one", () => {
    expect(inlineImageTransport({ TERM: "xterm-kitty" })).toBe("direct");
    expect(inlineImageTransport({ TERM: "xterm-256color", TERM_PROGRAM: "Apple_Terminal" })).toBe(
      null,
    );
  });

  it("uses tmux passthrough only when tmux's client terminal is known", () => {
    const pane = { TMUX: "/tmp/tmux-1000/default,1,0", TERM: "tmux-256color" };
    expect(inlineImageTransport(pane, () => "TERM_PROGRAM=ghostty\n")).toBe("tmux");
    expect(inlineImageTransport(pane, () => "TERM_PROGRAM=Alacritty\n")).toBe(null);
  });
});
