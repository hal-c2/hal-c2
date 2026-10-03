import type { SettingsSections } from "../settingsSections.ts";
import { backgroundActivitySection } from "./backgroundActivity.ts";
import { diagnosticsSection } from "./diagnostics.ts";
import { resourceMonitorSection } from "./resourceMonitor.ts";
import { scheduledTasksSection } from "./scheduledTasks.ts";
import { sourceControlSection } from "./sourceControl.ts";

/** The settings pages the terminal has, in the order the palette lists them. */
import { storageSection } from "./storage.ts";

export function registerSettingsSections(sections: SettingsSections): void {
  sections.register("scheduledTasks", scheduledTasksSection);
  sections.register("storage", storageSection);
  sections.register("sourceControl", sourceControlSection);
  sections.register("backgroundActivity", backgroundActivitySection);
  sections.register("diagnostics", diagnosticsSection);
  sections.register("resourceMonitor", resourceMonitorSection);
}
