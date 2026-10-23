import type { SectionHost, SectionItem, SettingsSection } from "../settingsSections.ts";
import { changeSettings, errorText, type Machine, readMachines, readSettings } from "./shared.ts";

type Subagents = "provider" | "hal-c2";

/** `settings.nativeSubagents` as stored: anything but "hal-c2" leaves the provider's own on. */
export const readSubagents = (settings: Readonly<Record<string, unknown>>): Subagents =>
  settings.nativeSubagents === "hal-c2" ? "hal-c2" : "provider";

const LABEL: Record<Subagents, string> = {
  provider: "Provider's own",
  "hal-c2": "HAL-C2 workers",
};

/**
 * Whose subagents agents use: the provider's own built-in ones, or HAL-C2's
 * workers (`delegate_task`) with the provider's turned off where it allows.
 * It applies when an agent's session next starts (`settings.nativeSubagents`).
 */
export function subagentsSection(host: SectionHost): SettingsSection {
  const { client } = host;
  let machines: Machine[] = [];
  let machineId: string | null = null;
  let value: Subagents | null = null;
  let error: string | null = null;
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
          return target ? readSettings(client, target) : null;
        })
        .then(
          (document) => {
            if (asked !== generation || document === null) return;
            value = readSubagents(document.settings);
            error = null;
            host.refresh();
          },
          (cause: unknown) => {
            if (asked !== generation) return;
            error = errorText(cause);
            host.refresh();
          },
        ),
    );
  };

  const write = (next: Subagents) => {
    const target = machine();
    if (!target) return;
    value = next;
    host.refresh();
    void host.track(
      changeSettings(client, target, (settings) => ({ ...settings, nativeSubagents: next })).then(
        () => host.status("Subagents saved.", "success"),
        (cause: unknown) => {
          host.status(`Could not save subagents: ${errorText(cause)}`, "error");
          load();
        },
      ),
    );
  };

  return {
    id: "subagents",
    commands: () => [
      {
        id: "section.subagents",
        title: "Subagents",
        keywords: "agent subagent provider delegate worker background task native settings",
        action: "section.open",
        payload: { id: "subagents" },
      },
    ],
    open: () => {
      value = null;
      error = null;
      machineId = null;
      load();
    },
    close: () => {
      generation += 1;
    },
    page: () => {
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
            value = null;
            load();
            host.refresh();
          },
        });
      }
      if (error !== null) items.push({ kind: "note", text: error, tone: "error" });
      const current = value;
      if (current === null) {
        if (error === null) items.push({ kind: "note", text: "Reading subagents…" });
        return { title: "subagents", items };
      }
      items.push({
        kind: "row",
        id: "subagents",
        label: "Subagents",
        value: LABEL[current],
        tone: "accent",
        run: () => write(current === "hal-c2" ? "provider" : "hal-c2"),
      });
      items.push({
        kind: "note",
        text:
          current === "hal-c2"
            ? "The provider's built-in subagents are turned off where it allows. Agents delegate to HAL-C2 workers, which have threads you can open. Applies when an agent's session next starts."
            : "Agents may use their provider's own built-in subagents, including background ones, whose work shows only as a summary.",
      });
      return { title: "subagents", items };
    },
  };
}
