import type { SectionHost, SectionItem, SettingsSection } from "../settingsSections.ts";
import {
  canChange,
  changeSettings,
  errorText,
  type Machine,
  readMachines,
  readSettings,
} from "./shared.ts";

/** A CLIProxyAPI hub as `settings.usageLimitSources` keeps it. */
interface WireHub {
  readonly kind?: string;
  readonly label?: string;
  readonly url: string;
}

/**
 * A hub's settings key: stable per hub and readable in settings.json. Dots and
 * dashes in the host are kept; a port's colon and anything else become a dash.
 */
export function hubIdFromUrl(url: string): string {
  let host = url;
  try {
    host = new URL(url).host;
  } catch {
    // Keep the raw text; the server reports the bad URL on its row.
  }
  const slug = host
    .toLowerCase()
    .replace(/[^a-z0-9.-]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return `cliproxy-${slug || "hub"}`;
}

/** How a hub is listed: its label, or its host when it was given none. */
export function hubLabel(hub: WireHub): string {
  if (hub.label?.trim()) return hub.label.trim();
  try {
    return new URL(hub.url).host;
  } catch {
    return hub.url;
  }
}

/**
 * Usage hubs: the CLIProxyAPI hubs whose accounts' limits a machine reports
 * beside its own. A hub is added with its URL and management key (the MC keeps
 * the key in its secret store) and removed again; the hub itself is never
 * written to. A machine linked for reading only lists its hubs and no more.
 */
export function usageHubsSection(host: SectionHost): SettingsSection {
  const { client } = host;
  let machines: Machine[] = [];
  let machineId: string | null = null;
  let hubs: ReadonlyArray<{ readonly id: string; readonly hub: WireHub }> | null = null;
  let error: string | null = null;
  /** The add form, open on its own page. */
  let form: { url: string; key: string; label: string; problem: string | null } | null = null;
  let generation = 0;

  const machine = () =>
    machines.find((candidate) => candidate.id === machineId) ??
    machines.find((candidate) => candidate.local) ??
    null;

  const load = () => {
    const asked = ++generation;
    void host.track(
      readMachines(client)
        .then((next) => {
          if (asked !== generation) return null;
          machines = next;
          const target = machine();
          return target?.online ? readSettings(client, target) : null;
        })
        .then(
          (document) => {
            if (asked !== generation) return;
            const sources = (document?.settings.usageLimitSources ?? {}) as Record<string, WireHub>;
            hubs = Object.entries(sources).map(([id, hub]) => ({ id, hub }));
            error = null;
            host.refresh();
          },
          (cause: unknown) => {
            if (asked !== generation) return;
            error = errorText(cause);
            hubs = [];
            host.refresh();
          },
        ),
    );
  };

  const write = (
    change: (sources: Record<string, unknown>) => Record<string, unknown>,
    done: string,
  ) => {
    const target = machine();
    if (!target) return;
    void host.track(
      changeSettings(client, target, (settings) => ({
        ...settings,
        usageLimitSources: change({
          ...(settings.usageLimitSources as Record<string, unknown> | undefined),
        }),
      })).then(
        () => {
          host.status(done, "success");
          load();
        },
        (cause: unknown) => {
          host.status(`Could not save the hub: ${errorText(cause)}`, "error");
          load();
        },
      ),
    );
  };

  const add = () => {
    if (!form) return;
    const url = form.url.trim();
    const key = form.key.trim();
    if (url === "" || key === "") {
      form.problem = "Enter the hub's URL and its management key.";
      host.status("A hub needs its URL and management key", "error");
      host.refresh();
      return;
    }
    const label = form.label.trim();
    form = null;
    write(
      (sources) => ({
        ...sources,
        [hubIdFromUrl(url)]: {
          kind: "cliproxy",
          ...(label === "" ? {} : { label }),
          url,
          managementKey: key,
          enabled: true,
        },
      }),
      "Hub added.",
    );
    host.refresh();
  };

  const formPage = (open: NonNullable<typeof form>): SectionItem[] => {
    const text = (id: "url" | "key" | "label", label: string, shown: string, hint: string) =>
      ({
        kind: "row",
        id: `hub-${id}`,
        label,
        value: shown === "" ? "—" : shown,
        run: () =>
          host.ask({ label, value: id === "key" ? "" : open[id], placeholder: hint }, (next) => {
            open[id] = next;
            open.problem = null;
            host.refresh();
          }),
      }) satisfies SectionItem;
    return [
      ...(open.problem ? [{ kind: "note", text: open.problem, tone: "error" } as const] : []),
      text("url", "URL", open.url, "https://hub.example:8317"),
      // The key is not shown again once typed.
      text("key", "Management key", open.key === "" ? "" : "••••••", "the hub's management key"),
      text("label", "Label (optional)", open.label, "Team hub"),
      { kind: "blank" },
      { kind: "row", id: "hub-add", label: "Add hub", tone: "accent", run: add },
    ];
  };

  const listPage = (): SectionItem[] => {
    const items: SectionItem[] = [];
    const target = machine();
    if (machines.length > 1 && target) {
      items.push({
        kind: "row",
        id: "machine",
        label: "Machine",
        value: target.label,
        run: () => {
          machineId = machines[(machines.indexOf(target) + 1) % machines.length]!.id;
          hubs = null;
          load();
          host.refresh();
        },
      });
    }
    if (target && !target.online) {
      items.push({
        kind: "note",
        text: `Reconnect ${target.label} to see its hubs.`,
        tone: "warning",
      });
      return items;
    }
    const writable = target !== null && canChange(target);
    if (target && !writable) {
      items.push({
        kind: "note",
        text: `This session can view ${target.label}'s hubs but can't change them.`,
        tone: "warning",
      });
    }
    if (error !== null) items.push({ kind: "note", text: error, tone: "error" });
    if (hubs === null) {
      items.push({ kind: "note", text: "Reading hubs…" });
      return items;
    }
    if (hubs.length === 0) {
      items.push({
        kind: "note",
        text: "No hubs. A CLIProxyAPI hub pools provider accounts; adding one puts their limits next to this machine's own.",
      });
    }
    for (const { id, hub } of hubs) {
      items.push({
        kind: "row",
        id: `hub-${id}`,
        label: hubLabel(hub),
        value: writable ? `${hub.url} · Enter removes` : hub.url,
        ...(writable
          ? {
              run: () =>
                host.confirm(
                  `Remove the hub "${hubLabel(hub)}"? Its key is deleted from this server; the hub itself is not touched.`,
                  () =>
                    write((sources) => {
                      const { [id]: _removed, ...rest } = sources;
                      return rest;
                    }, "Hub removed."),
                ),
            }
          : {}),
      });
    }
    if (writable) {
      items.push({ kind: "blank" });
      items.push({
        kind: "row",
        id: "add",
        label: "+ Add a CLIProxyAPI hub",
        tone: "accent",
        run: () => {
          form = { url: "", key: "", label: "", problem: null };
          host.refresh();
          host.select("hub-url");
        },
      });
    }
    return items;
  };

  return {
    id: "usageHubs",
    commands: () => [
      {
        id: "section.usageHubs",
        title: "Usage hubs",
        keywords: "usage providers limits cliproxy hub accounts settings",
        action: "section.open",
        payload: { id: "usageHubs" },
      },
    ],
    open: (payload) => {
      const environmentId = (payload as { readonly environmentId?: unknown } | undefined)
        ?.environmentId;
      machineId = typeof environmentId === "string" ? environmentId : null;
      hubs = null;
      error = null;
      form = null;
      load();
    },
    close: () => {
      generation += 1;
      form = null;
    },
    back: () => {
      if (!form) return false;
      form = null;
      return true;
    },
    page: () =>
      form
        ? { title: "usage hubs · add a hub", items: formPage(form) }
        : { title: "usage hubs", items: listPage() },
  };
}
