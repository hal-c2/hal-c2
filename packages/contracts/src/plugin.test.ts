import { describe, expect, it } from "vite-plus/test";
import * as Schema from "effect/Schema";

import { PluginManifest, PluginSettingField } from "./plugin.ts";

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
