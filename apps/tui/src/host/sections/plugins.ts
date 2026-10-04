import * as NodePath from "node:path";

import type { TuiProblem } from "../host.ts";
import type { TuiPluginsState } from "../plugins.ts";
import type { SectionHost, SectionItem, SettingsSection } from "../settingsSections.ts";

/** What the plugins page reads and does; the host owns the plugins themselves. */
export interface PluginsPageHost {
  readonly view: () => TuiPluginsState & { readonly problems: ReadonlyArray<TuiProblem> };
  readonly disable: (id: string) => void;
  readonly enable: (id: string) => void;
  /** Download a plugin file and load it. */
  readonly install: (url: string) => void;
}

/** `plugin "/home/u/.config/…/flaky.qml"` or `plugin "flaky" (render, …)` → `flaky`. */
function failedPlugin(where: string | null): string | null {
  const named = /^plugin "([^"]+)"/.exec(where ?? "")?.[1];
  if (named === undefined) return null;
  return named.endsWith(".qml") ? NodePath.basename(named, ".qml") : named;
}

/**
 * Plugins: what this client has loaded (a QML file, or one built in), the ones
 * turned off, and the ones that failed with what went wrong. Enter on a plugin
 * turns it off or on again; a plugin file can be loaded from a URL, after the
 * user has been told that nothing vouches for it.
 */
export function pluginsSection(host: SectionHost, plugins: PluginsPageHost): SettingsSection {
  const fromUrl = () =>
    host.ask({ label: "plugin URL", placeholder: "https://…/plugin.qml" }, (address) => {
      if (address === "") return;
      let where = address;
      try {
        where = new URL(address).host;
      } catch {
        // Said by the install itself.
      }
      host.confirm(
        `This plugin is not signed: nothing vouches for what ${where} serves, and a plugin runs with this client's own access. Load it?`,
        () => plugins.install(address),
        () => host.status("Nothing was loaded.", "info"),
      );
    });

  return {
    id: "plugins",
    commands: () => [
      {
        id: "section.plugins",
        title: "Plugins",
        keywords: "extensions installed disable enable load url errors settings",
        action: "section.open",
        payload: { id: "plugins" },
      },
    ],
    open: () => {},
    page: () => {
      const view = plugins.view();
      const items: SectionItem[] = [];
      if (view.items.length + view.disabled.length === 0) {
        items.push({ kind: "note", text: "No plugins are installed." });
      }
      for (const plugin of view.items) {
        const source = view.sources[plugin.id];
        items.push({
          kind: "row",
          id: `plugin-${plugin.id}`,
          label: plugin.id,
          value: ["enabled", plugin.file === null ? "built in" : (source ?? plugin.file)].join(
            " · ",
          ),
          run: () => plugins.disable(plugin.id),
        });
      }
      for (const plugin of view.disabled) {
        items.push({
          kind: "row",
          id: `plugin-${plugin.id}`,
          label: plugin.id,
          value: `disabled · ${plugin.file}`,
          run: () => plugins.enable(plugin.id),
        });
      }
      const failures = view.problems.flatMap((problem) => {
        const id = failedPlugin(problem.where);
        return id === null || problem.level !== "error" ? [] : [{ id, message: problem.message }];
      });
      if (failures.length > 0) {
        items.push({ kind: "blank" });
        items.push({ kind: "heading", text: "Failed" });
        for (const failure of failures) {
          items.push({ kind: "note", tone: "error", text: `${failure.id}: ${failure.message}` });
        }
      }
      items.push({ kind: "blank" });
      items.push({ kind: "row", id: "url", label: "Load a plugin from a URL…", run: fromUrl });
      return { title: "plugins", items };
    },
  };
}
