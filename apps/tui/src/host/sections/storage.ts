import type { SectionHost, SectionItem, SettingsSection } from "../settingsSections.ts";
import {
  changeSettings,
  errorText,
  type Machine,
  readMachines,
  readSettings,
  type SettingsDocument,
} from "./shared.ts";

/** A cleanup rule: on or off, or a number of days (null is off). */
export type StorageValue = boolean | number | null;

interface Rule {
  readonly key: string;
  readonly label: string;
  readonly days: boolean;
}

/** The MC's cleanup rules (`settings.storageCleanup`); every one is off until turned on. */
export const STORAGE_RULES: ReadonlyArray<Rule> = [
  { key: "worktreeOnDelete", label: "Delete worktrees with deleted threads", days: false },
  { key: "worktreeAfterDays", label: "Delete inactive worktrees", days: true },
  { key: "worktreeOnMerge", label: "Delete merged worktrees", days: false },
  { key: "worktreeUnchanged", label: "Delete unchanged worktrees", days: false },
  { key: "browserArtifactsAfterDays", label: "Delete old browser artifacts", days: true },
  { key: "logsAfterDays", label: "Delete old rotated logs", days: true },
];

const UPDATE_NOTICE =
  "Update the selected environments to use storage cleanup, or choose a machine that supports it.";

/** What a rule reads across the machines in scope: their one value, or mixed. */
export function ruleValue(
  rule: Rule,
  documents: ReadonlyArray<SettingsDocument>,
): { readonly mixed: boolean; readonly value: StorageValue } {
  const values = documents.map((document) => {
    const cleanup = (document.settings.storageCleanup ?? {}) as Record<string, StorageValue>;
    return cleanup[rule.key] ?? (rule.days ? null : false);
  });
  const first = values[0] ?? (rule.days ? null : false);
  return { mixed: values.some((value) => value !== first), value: first };
}

/**
 * Storage settings: the rules by which the MC removes worktrees and old files
 * it made. They are read from and written to one machine or all of them; a
 * rule the machines disagree on reads "mixed" until it is set.
 */
export function storageSection(host: SectionHost): SettingsSection {
  const { client } = host;
  let machines: Machine[] = [];
  /** The machine in scope; null is all of them. Starts on this machine. */
  let scope: string | null = null;
  let scopeChosen = false;
  const documents = new Map<string, SettingsDocument>();
  let error: string | null = null;
  /** Machines the last change could not reach. */
  let failed: string[] = [];
  let loading = true;
  let generation = 0;

  const targets = () =>
    scope === null ? machines : machines.filter((machine) => machine.id === scope);
  const supported = (machine: Machine) =>
    machine.capabilities === null || machine.capabilities.storageCleanup === true;

  const load = () => {
    const asked = ++generation;
    loading = true;
    void host.track(
      readMachines(client).then(async (next) => {
        if (asked !== generation) return;
        machines = next;
        if (!scopeChosen) scope = next.find((machine) => machine.local)?.id ?? null;
        error = null;
        await Promise.all(
          targets()
            .filter((machine) => machine.online && supported(machine))
            .map((machine) =>
              readSettings(client, machine).then(
                (document) => {
                  if (asked === generation) documents.set(machine.id, document);
                },
                (cause: unknown) => {
                  if (asked === generation) error = `${machine.label}: ${errorText(cause)}`;
                },
              ),
            ),
        );
        if (asked !== generation) return;
        loading = false;
        host.refresh();
      }),
    );
    host.refresh();
  };

  const set = (rule: Rule, value: StorageValue) => {
    const asked = generation;
    void host.track(
      Promise.all(
        targets().map((machine) =>
          changeSettings(client, machine, (settings) => ({
            ...settings,
            storageCleanup: {
              ...(settings.storageCleanup as object | undefined),
              [rule.key]: value,
            },
          })).then(
            () => null,
            () => machine.label,
          ),
        ),
      ).then((results) => {
        if (asked !== generation) return;
        failed = results.filter((label): label is string => label !== null);
        if (failed.length === 0) host.status("Storage setting saved.", "success");
        else if (failed.length === results.length)
          host.status("Could not save the setting", "error");
        else host.status("Setting saved on some environments", "error");
        load();
      }),
    );
  };

  const scopeLabel = () =>
    scope === null
      ? "All machines"
      : (machines.find((machine) => machine.id === scope)?.label ?? scope);

  return {
    id: "storage",
    commands: () => [
      {
        id: "section.storage",
        title: "Storage settings",
        keywords: "cleanup worktrees disk logs artifacts delete",
        action: "section.open",
        payload: { id: "storage" },
      },
    ],
    open: () => {
      documents.clear();
      machines = [];
      scope = null;
      scopeChosen = false;
      failed = [];
      load();
    },
    close: () => {
      generation += 1;
    },
    page: () => {
      const items: SectionItem[] = [];
      if (machines.length > 1) {
        items.push({
          kind: "row",
          id: "scope",
          label: "Applies to",
          value: scopeLabel(),
          run: () => {
            const ids: Array<string | null> = [...machines.map((machine) => machine.id), null];
            scope = ids[(ids.indexOf(scope) + 1) % ids.length] ?? null;
            scopeChosen = true;
            failed = [];
            load();
          },
        });
        items.push({ kind: "blank" });
      }
      if (loading && machines.length === 0) {
        items.push({ kind: "note", text: "Reading storage settings…" });
        return { title: "storage", items };
      }
      const inScope = targets();
      const offline = inScope.filter((machine) => !machine.online);
      if (offline.length > 0) {
        items.push({
          kind: "note",
          text: `Reconnect ${offline.map((machine) => machine.label).join(", ")} to change this setting.`,
          tone: "warning",
        });
        return { title: "storage", items };
      }
      if (inScope.some((machine) => !supported(machine))) {
        items.push({ kind: "note", text: UPDATE_NOTICE, tone: "warning" });
        return { title: "storage", items };
      }
      if (error !== null) items.push({ kind: "note", text: error, tone: "error" });
      if (failed.length > 0) {
        items.push({
          kind: "note",
          text: `Could not update ${failed.join(", ")}.`,
          tone: "error",
        });
      }
      const read = inScope.flatMap((machine) => documents.get(machine.id) ?? []);
      if (read.length < inScope.length) {
        if (error === null) items.push({ kind: "note", text: "Reading storage settings…" });
        return { title: "storage", items };
      }
      items.push({
        kind: "note",
        text: "Cleanup errs on the side of keeping work. Every rule is off until turned on.",
      });
      for (const rule of STORAGE_RULES) {
        const { mixed, value } = ruleValue(rule, read);
        items.push({
          kind: "row",
          id: `rule-${rule.key}`,
          label: rule.label,
          value: mixed
            ? "mixed"
            : rule.days
              ? value === null
                ? "off"
                : `after ${value} days`
              : value === true
                ? "on"
                : "off",
          tone: mixed ? "warning" : value === null || value === false ? "dim" : "success",
          run: rule.days
            ? () =>
                host.ask(
                  {
                    label: "Days",
                    value: mixed || value === null ? "" : String(value),
                    placeholder: "a number of days, or blank to turn it off",
                  },
                  (text) => {
                    const days = Number(text);
                    if (text === "") set(rule, null);
                    else if (Number.isInteger(days) && days > 0) set(rule, days);
                    else host.status("Enter a whole number of days", "error");
                  },
                )
            : () => set(rule, mixed ? true : value !== true),
        });
      }
      return { title: "storage", items };
    },
  };
}
