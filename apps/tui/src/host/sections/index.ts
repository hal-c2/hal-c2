import type { SettingsSections } from "../settingsSections.ts";
import { diagnosticsSection } from "./diagnostics.ts";
import { resourceMonitorSection } from "./resourceMonitor.ts";
import { sourceControlSection } from "./sourceControl.ts";

/** The settings pages the terminal has, in the order the palette lists them. */
export function registerSettingsSections(sections: SettingsSections): void {
  sections.register("sourceControl", sourceControlSection);
  sections.register("diagnostics", diagnosticsSection);
  sections.register("resourceMonitor", resourceMonitorSection);
}
