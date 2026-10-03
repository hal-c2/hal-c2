import type { SettingsSections } from "../settingsSections.ts";
import { backgroundActivitySection } from "./backgroundActivity.ts";
import type { ProjectScript } from "@hal-c2/contracts";

import { diagnosticsSection } from "./diagnostics.ts";
import { projectsSection } from "./projects.ts";
import { resourceMonitorSection } from "./resourceMonitor.ts";
import { scheduledTasksSection } from "./scheduledTasks.ts";
import { sourceControlSection } from "./sourceControl.ts";

/** The settings pages the terminal has, in the order the palette lists them. */
import { storageSection } from "./storage.ts";
import { updatesSection } from "./updates.ts";
import { usageHubsSection } from "./usageHubs.ts";
import { usageLimitsSection } from "./usageLimits.ts";

export function registerSettingsSections(
  sections: SettingsSections,
  options: {
    /** The version this app shipped as; null when it was not told. */
    readonly appVersion: string | null;
    /** A server was updated: whatever follows its version reads it again. */
    readonly serverUpdated: () => void;
    /** Run a project action in the open thread's terminal; false when it cannot. */
    readonly runProjectAction: (projectId: string, script: ProjectScript) => boolean;
  },
): void {
  sections.register("projects", (host) =>
    projectsSection(host, { runAction: options.runProjectAction }),
  );
  sections.register("scheduledTasks", scheduledTasksSection);
  sections.register("storage", storageSection);
  sections.register("sourceControl", sourceControlSection);
  sections.register("backgroundActivity", backgroundActivitySection);
  sections.register("diagnostics", diagnosticsSection);
  sections.register("resourceMonitor", resourceMonitorSection);
  sections.register("usageLimits", usageLimitsSection);
  sections.register("usageHubs", usageHubsSection);
  sections.register("updates", (host) =>
    updatesSection(host, { appVersion: options.appVersion, updated: options.serverUpdated }),
  );
}
