import { SETTINGS_SECTION_LABELS, type SettingsPath } from "../components/settings/settingsSearch";

const SETTINGS_SECTIONS: ReadonlyArray<{ to: SettingsPath; label: string }> = (
  Object.keys(SETTINGS_SECTION_LABELS) as SettingsPath[]
).map((to) => ({ to, label: SETTINGS_SECTION_LABELS[to] }));

export function isSettingsPath(value: string): value is SettingsPath {
  return Object.hasOwn(SETTINGS_SECTION_LABELS, value);
}

export function resolveActiveSettingsSection(pathname: string): SettingsPath | null {
  return (
    SETTINGS_SECTIONS.find(
      (section) => pathname === section.to || pathname.startsWith(`${section.to}/`),
    )?.to ?? null
  );
}
