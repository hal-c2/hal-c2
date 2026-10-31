import { describe, expect, it } from "vite-plus/test";
import * as Schema from "effect/Schema";

import { PluginCompileCheck, PluginEntry, PluginManifest, PluginSettingField } from "./plugin.ts";

const decodeManifest = Schema.decodeUnknownSync(PluginManifest);

const minimal = {
  id: "clock",
  name: "Clock",
  version: "1.0.0",
  apiVersion: 1,
  description: "Shows the time.",
};

describe("PluginManifest", () => {
  it("accepts a package with only the required fields", () => {
    expect(decodeManifest(minimal)).toEqual(minimal);
  });

  it.each(["../escape.qml", "/etc/passwd", "ui/../../escape.qml"])(
    "refuses the package path %s",
    (qml) => {
      expect(() =>
        decodeManifest({
          ...minimal,
          contributes: { pages: [{ id: "main", title: "Main", qml }] },
        }),
      ).toThrow();
    },
  );

  it("refuses ids that cannot be a directory name", () => {
    expect(() => decodeManifest({ ...minimal, id: "Code Review" })).toThrow();
  });

  it.each([
    ["an @ in it", [{ id: "main@2", title: "Main", qml: "ui/Main.qml" }]],
    [
      "another page's id",
      [
        { id: "main", title: "Main", qml: "ui/Main.qml" },
        { id: "main", title: "Other", qml: "ui/Other.qml" },
      ],
    ],
  ])("refuses a page id with %s", (_, pages) => {
    expect(() => decodeManifest({ ...minimal, contributes: { pages } })).toThrow();
  });

  it("refuses permissions the MC does not know", () => {
    expect(() =>
      decodeManifest({ ...minimal, permissions: [{ id: "root", reason: "Because" }] }),
    ).toThrow();
  });

  it("types each settings field", () => {
    const decode = Schema.decodeUnknownSync(PluginSettingField);
    expect(
      decode({ key: "mode", label: "Mode", type: "choice", options: [{ value: "a", label: "A" }] }),
    ).toMatchObject({ type: "choice" });
    expect(() => decode({ key: "mode", label: "Mode", type: "choice" })).toThrow();
  });

  it.each([
    ["is not one of its options", "b"],
    ["is turned off", "a"],
  ])("refuses a choice whose default %s", (_, value) => {
    const decode = Schema.decodeUnknownSync(PluginSettingField);
    const options = [
      { value: "a", label: "A", disabled: true },
      { value: "c", label: "C" },
    ];
    expect(() =>
      decode({ key: "mode", label: "Mode", type: "choice", options, default: value }),
    ).toThrow();
    expect(
      decode({ key: "mode", label: "Mode", type: "choice", options, default: "c" }),
    ).toMatchObject({
      default: "c",
    });
  });
});

describe("PluginCompileCheck", () => {
  const decode = Schema.decodeUnknownSync(PluginCompileCheck);

  it("takes a failure the MC locates and one it cannot", () => {
    const check = {
      ok: false,
      error: "mc/broken.ex:2: syntax error before: ')'",
      diagnostics: [
        { file: "mc/broken.ex", line: 2, message: "syntax error before: ')'", severity: "error" },
        { file: null, line: null, message: "has two plugin modules", severity: "error" },
      ],
      checkedAt: "2026-10-29T12:00:00Z",
    };
    expect(decode(check)).toEqual(check);
  });

  it("refuses a severity the compiler does not give", () => {
    expect(() =>
      decode({
        ok: true,
        error: null,
        diagnostics: [{ file: null, line: null, message: "x", severity: "fatal" }],
        checkedAt: "2026-10-29T12:00:00Z",
      }),
    ).toThrow();
  });
});

describe("PluginEntry", () => {
  const decode = Schema.decodeUnknownSync(PluginEntry);
  const entry = {
    id: "notes",
    name: "Notes",
    version: "1",
    kind: null,
    kinds: [],
    apiVersion: 1,
    source: "package",
    file: null,
    description: null,
    author: null,
    homepage: null,
    license: null,
    icon: null,
    screenshots: [],
    enabled: false,
    status: "disabled",
    error: null,
    reloadError: null,
    lastError: null,
    restarts: 0,
    runsCode: true,
    settingsSchema: [],
    settings: {},
    permissions: [],
    denied: [],
    contributes: {},
    revision: "1",
  };

  it("takes an entry from an MC older than the compile check", () => {
    expect(decode(entry)).toEqual(entry);
    expect(decode({ ...entry, compileCheck: null }).compileCheck).toBeNull();
  });
});
