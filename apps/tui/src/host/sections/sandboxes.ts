import type { ServerOpenShellStatus } from "@hal-c2/contracts";

import type { SectionHost, SectionItem, SettingsSection } from "../settingsSections.ts";
import { errorText } from "./shared.ts";

const MODES: Record<string, string> = {
  managed: "run by this MC",
  external: "a gateway you run",
  foreground: "the dev run",
};

/**
 * Review sandboxes: whether this environment can run code reviews in an
 * OpenShell sandbox and, when it can't, what is wrong and what to do, from the
 * MC's `server.getOpenShellStatus`. Read when the page opens and on Refresh.
 */
export function sandboxesSection(host: SectionHost): SettingsSection {
  let status: ServerOpenShellStatus | null = null;
  let error: string | null = null;
  let loading = false;
  let generation = 0;

  const read = () => {
    const asked = ++generation;
    loading = true;
    void host.track(
      host.client.mcCall<ServerOpenShellStatus>("server.getOpenShellStatus", {}).then(
        (next) => {
          if (asked !== generation) return;
          loading = false;
          status = next;
          error = null;
          host.refresh();
        },
        (cause: unknown) => {
          if (asked !== generation) return;
          loading = false;
          status = null;
          error = errorText(cause);
          host.refresh();
        },
      ),
    );
    host.refresh();
  };

  const summary = (): SectionItem[] => {
    if (error !== null) {
      return [
        {
          kind: "note",
          text: "Could not read whether review sandboxes can run here.",
          tone: "error",
        },
        { kind: "note", text: error },
      ];
    }
    if (status === null) {
      return [{ kind: "note", text: "Asking the MC whether review sandboxes can run here…" }];
    }
    const problems: SectionItem[] = status.problems.map((problem) => ({
      kind: "note",
      text: problem.message,
    }));
    if (!status.supported) {
      return [
        { kind: "note", text: "Review sandboxes can't run on this machine.", tone: "warning" },
        { kind: "note", text: "Code reviews run without a sandbox here.", tone: "dim" },
        ...problems,
      ];
    }
    if (!status.ready) {
      return [
        { kind: "note", text: "Review sandboxes can't run here yet.", tone: "warning" },
        {
          kind: "note",
          text: `OpenShell ${status.pinnedVersion} is the version this MC pins.`,
          tone: "dim",
        },
        ...problems,
      ];
    }
    const mode = status.mode === null ? null : (MODES[status.mode] ?? status.mode);
    return [
      { kind: "note", text: "Review sandboxes can run here.", tone: "success" },
      {
        kind: "note",
        text: [`OpenShell${status.version === null ? "" : ` ${status.version}`}`, mode]
          .filter((part) => part !== null)
          .join(", ")
          .concat("."),
        tone: "dim",
      },
    ];
  };

  return {
    id: "sandboxes",
    commands: () => [
      {
        id: "section.sandboxes",
        title: "Review sandboxes",
        keywords: "openshell sandbox code review gateway podman docker container isolation install",
        action: "section.open",
        payload: { id: "sandboxes" },
      },
    ],
    open: () => {
      status = null;
      error = null;
      read();
    },
    close: () => {
      generation += 1;
    },
    page: () => ({
      title: "review sandboxes",
      items: [
        ...summary(),
        { kind: "blank" },
        loading
          ? { kind: "row", id: "refresh", label: "Checking…", tone: "dim" }
          : { kind: "row", id: "refresh", label: "Refresh", run: read },
      ],
    }),
  };
}
