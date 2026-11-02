import { describe, expect, it } from "bun:test";

import { runnableShellCommand } from "./shellRun.ts";

const block = (source: string, language = "bash", closed = true) => ({ source, language, closed });

describe("runnableShellCommand", () => {
  it("runs one closed line of shell, trimmed", () => {
    expect(runnableShellCommand(block("  npm test "), false)).toBe("npm test");
    for (const language of ["sh", "zsh", "fish", "shell", "powershell", "pwsh"]) {
      expect(runnableShellCommand(block("ls", language), false)).toBe("ls");
    }
  });

  it("offers no run while streaming or before the fence closes", () => {
    expect(runnableShellCommand(block("ls"), true)).toBeNull();
    expect(runnableShellCommand(block("ls", "bash", false), false)).toBeNull();
  });

  it("offers no run for other languages, empty, multi-line or continued commands", () => {
    expect(runnableShellCommand(block("print(1)", "python"), false)).toBeNull();
    expect(runnableShellCommand(block("ls", ""), false)).toBeNull();
    expect(runnableShellCommand(block("   "), false)).toBeNull();
    expect(runnableShellCommand(block("cd app\nnpm test"), false)).toBeNull();
    expect(runnableShellCommand(block("npm test \\"), false)).toBeNull();
  });

  it("offers no run when the command hides control or format characters", () => {
    expect(runnableShellCommand(block("rm ‮fdp.txt"), false)).toBeNull();
    expect(runnableShellCommand(block("ls​"), false)).toBeNull();
    expect(runnableShellCommand(block("ls\tfoo"), false)).toBeNull();
  });
});
