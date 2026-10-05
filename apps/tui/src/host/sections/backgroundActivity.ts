import type { SectionHost, SectionItem, SettingsSection } from "../settingsSections.ts";
import { changeSettings, errorText, type Machine, readMachines, readSettings } from "./shared.ts";

type Profile = "balanced" | "performance" | "battery-saver";
type Selection = Profile | "custom";

/** What a profile sets; intervals in milliseconds, 0 for never. */
export interface BackgroundPolicy {
  readonly automaticGitFetchInterval: number;
  readonly providerHealthRefreshInterval: number;
  readonly pauseWhenHostLocked: boolean;
  readonly pauseWhenHostLowPower: boolean;
  readonly pauseWhenClientLowPower: boolean;
  readonly pauseWhenOnBattery: boolean;
}

/** The MC's presets (`HalC2.BackgroundPolicy`): what a custom profile starts from. */
export const BACKGROUND_PRESETS: Record<Profile, BackgroundPolicy> = {
  performance: {
    automaticGitFetchInterval: 15_000,
    providerHealthRefreshInterval: 60_000,
    pauseWhenHostLocked: true,
    pauseWhenHostLowPower: false,
    pauseWhenClientLowPower: false,
    pauseWhenOnBattery: false,
  },
  balanced: {
    automaticGitFetchInterval: 30_000,
    providerHealthRefreshInterval: 300_000,
    pauseWhenHostLocked: true,
    pauseWhenHostLowPower: true,
    pauseWhenClientLowPower: true,
    pauseWhenOnBattery: false,
  },
  "battery-saver": {
    automaticGitFetchInterval: 0,
    providerHealthRefreshInterval: 900_000,
    pauseWhenHostLocked: true,
    pauseWhenHostLowPower: true,
    pauseWhenClientLowPower: true,
    pauseWhenOnBattery: true,
  },
};

interface Activity {
  readonly profile: Selection;
  readonly baseProfile: Profile;
  readonly overrides: Partial<BackgroundPolicy>;
}

const isProfile = (value: unknown): value is Profile =>
  value === "balanced" || value === "performance" || value === "battery-saver";

/** `settings.backgroundActivity` as it is stored, with the MC's defaults filled in. */
export function readActivity(settings: Readonly<Record<string, unknown>>): Activity {
  const stored = (settings.backgroundActivity ?? {}) as Record<string, unknown>;
  const custom = stored.profile === "custom";
  return {
    profile: custom ? "custom" : isProfile(stored.profile) ? stored.profile : "balanced",
    baseProfile: custom
      ? isProfile(stored.baseProfile)
        ? stored.baseProfile
        : "balanced"
      : isProfile(stored.profile)
        ? stored.profile
        : "balanced",
    overrides: custom ? ((stored.overrides ?? {}) as Partial<BackgroundPolicy>) : {},
  };
}

/** The policy in effect: the base profile's preset with the custom overrides over it. */
export const effectivePolicy = (activity: Activity): BackgroundPolicy => ({
  ...BACKGROUND_PRESETS[activity.baseProfile],
  ...activity.overrides,
});

/** "30s", "2m", "1h" or a bare number of seconds, in milliseconds; null when it is none of them. */
export function parseInterval(text: string): number | null {
  const match = /^(\d+(?:\.\d+)?)\s*(s|sec|m|min|h)?$/i.exec(text.trim());
  if (!match) return null;
  const unit = (match[2] ?? "s").toLowerCase();
  const scale = unit.startsWith("h") ? 3_600_000 : unit.startsWith("m") ? 60_000 : 1000;
  return Math.round(Number(match[1]) * scale);
}

export function intervalLabel(ms: number): string {
  if (ms <= 0) return "never";
  if (ms % 3_600_000 === 0) return `every ${ms / 3_600_000} h`;
  if (ms % 60_000 === 0) return `every ${ms / 60_000} min`;
  return `every ${Math.round(ms / 1000)} sec`;
}

const PROFILE_LABEL: Record<Selection, string> = {
  balanced: "Balanced",
  performance: "Performance",
  "battery-saver": "Battery saver",
  custom: "Custom",
};
const PROFILE_ORDER: Selection[] = ["balanced", "performance", "battery-saver", "custom"];

const INTERVALS = [
  { key: "automaticGitFetchInterval", label: "Fetch git" },
  { key: "providerHealthRefreshInterval", label: "Check providers" },
] as const;
const PAUSES = [
  { key: "pauseWhenHostLocked", label: "Pause when the host is locked" },
  { key: "pauseWhenHostLowPower", label: "Pause when the host is on low power" },
  { key: "pauseWhenClientLowPower", label: "Pause when a client is on low power" },
  { key: "pauseWhenOnBattery", label: "Pause on battery" },
] as const;

/**
 * Background activity: how often the MC fetches git and checks providers, and
 * when it pauses. A profile sets all of it; "Custom" starts from the profile
 * it replaced and lets each value be set (`settings.backgroundActivity`).
 */
export function backgroundActivitySection(host: SectionHost): SettingsSection {
  const { client } = host;
  let machines: Machine[] = [];
  let machineId: string | null = null;
  let activity: Activity | null = null;
  let error: string | null = null;
  /** The profile list is open (its own page). */
  let choosing = false;
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
            activity = readActivity(document.settings);
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

  const write = (next: Activity) => {
    const target = machine();
    if (!target) return;
    activity = next;
    host.refresh();
    void host.track(
      changeSettings(client, target, (settings) => ({
        ...settings,
        backgroundActivity:
          next.profile === "custom"
            ? {
                schemaVersion: 1,
                profile: "custom",
                baseProfile: next.baseProfile,
                overrides: next.overrides,
              }
            : { schemaVersion: 1, profile: next.profile, overrides: {} },
      })).then(
        () => host.status("Background activity saved.", "success"),
        (cause: unknown) => {
          host.status(`Could not save background activity: ${errorText(cause)}`, "error");
          load();
        },
      ),
    );
  };

  const override = (current: Activity, patch: Partial<BackgroundPolicy>) =>
    write({ ...current, overrides: { ...current.overrides, ...patch } });

  return {
    id: "backgroundActivity",
    commands: () => [
      {
        id: "section.backgroundActivity",
        title: "Background activity",
        keywords: "git fetch interval provider check battery power profile advanced settings",
        action: "section.open",
        payload: { id: "backgroundActivity" },
      },
    ],
    back: () => {
      if (!choosing) return false;
      choosing = false;
      return true;
    },
    open: () => {
      choosing = false;
      activity = null;
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
            activity = null;
            load();
            host.refresh();
          },
        });
      }
      if (error !== null) items.push({ kind: "note", text: error, tone: "error" });
      const current = activity;
      if (current === null) {
        if (error === null) items.push({ kind: "note", text: "Reading background activity…" });
        return { title: "background activity", items };
      }
      if (choosing) {
        return {
          title: "background activity · Profile",
          items: PROFILE_ORDER.map((profile) => ({
            kind: "row" as const,
            id: `profile-${profile}`,
            label: PROFILE_LABEL[profile],
            value:
              profile === "custom"
                ? "set each value yourself (advanced)"
                : `git ${intervalLabel(BACKGROUND_PRESETS[profile].automaticGitFetchInterval)} · providers ${intervalLabel(BACKGROUND_PRESETS[profile].providerHealthRefreshInterval)}`,
            run: () => {
              choosing = false;
              if (profile !== current.profile) {
                write(
                  profile === "custom"
                    ? { profile: "custom", baseProfile: current.baseProfile, overrides: {} }
                    : { profile, baseProfile: profile, overrides: {} },
                );
              }
              host.refresh();
              host.select("profile");
            },
          })),
        };
      }
      const custom = current.profile === "custom";
      const policy = effectivePolicy(current);
      items.push({
        kind: "row",
        id: "profile",
        label: "Profile",
        value: custom
          ? `Custom (advanced), from ${PROFILE_LABEL[current.baseProfile]}`
          : PROFILE_LABEL[current.profile],
        tone: "accent",
        run: () => {
          choosing = true;
          host.refresh();
          host.select(`profile-${current.profile}`);
        },
      });
      items.push({
        kind: "note",
        text: custom
          ? "Each value below can be set. Intervals take seconds, or 2m, 1h; 0 turns one off."
          : "The profile sets the values below. Choose Custom to set them one by one.",
      });
      for (const { key, label } of INTERVALS) {
        items.push({
          kind: "row",
          id: `interval-${key}`,
          label,
          value: intervalLabel(policy[key]),
          ...(custom
            ? {
                run: () =>
                  host.ask(
                    {
                      label,
                      value: String(Math.round(policy[key] / 1000)),
                      placeholder: "seconds, or 2m, 1h; 0 for never",
                    },
                    (text) => {
                      const ms = parseInterval(text);
                      if (ms === null)
                        host.status("Enter an interval such as 90, 2m or 1h", "error");
                      else override(current, { [key]: ms });
                    },
                  ),
              }
            : {}),
        });
      }
      for (const { key, label } of PAUSES) {
        items.push({
          kind: "row",
          id: `pause-${key}`,
          label,
          value: policy[key] ? "on" : "off",
          tone: policy[key] ? "success" : "dim",
          ...(custom ? { run: () => override(current, { [key]: !policy[key] }) } : {}),
        });
      }
      return { title: "background activity", items };
    },
  };
}
