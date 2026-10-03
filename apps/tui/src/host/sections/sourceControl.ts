import type { SourceControlDiscoveryResult } from "@hal-c2/contracts";

import type { SectionHost, SectionItem, SettingsSection } from "../settingsSections.ts";
import { errorText, optionValue } from "./shared.ts";

/** How a tool reads in the list. */
export type ToolState = "authenticated" | "needs setup" | "unavailable" | "available";

export interface ToolRow {
  readonly label: string;
  readonly state: ToolState;
  /** The account, the version, or what to do about it. */
  readonly detail: string;
}

/** Each version-control and hosting tool with its state, as the page lists them. */
export function toolRows(discovery: SourceControlDiscoveryResult): ToolRow[] {
  const rows: ToolRow[] = [];
  for (const tool of discovery.versionControlSystems) {
    rows.push(
      tool.status === "available"
        ? {
            label: tool.label,
            state: "available",
            detail: optionValue<string>(tool.version) ?? "",
          }
        : { label: tool.label, state: "unavailable", detail: tool.installHint },
    );
  }
  for (const tool of discovery.sourceControlProviders) {
    if (tool.status !== "available") {
      rows.push({ label: tool.label, state: "unavailable", detail: tool.installHint });
    } else if (tool.auth.status === "authenticated") {
      const account = optionValue<string>(tool.auth.account);
      rows.push({
        label: tool.label,
        state: "authenticated",
        detail: account ? `as ${account}` : "",
      });
    } else {
      rows.push({
        label: tool.label,
        state: "needs setup",
        detail: optionValue<string>(tool.auth.detail) ?? tool.installHint,
      });
    }
  }
  return rows;
}

const TONE = {
  authenticated: "success",
  available: "success",
  "needs setup": "warning",
  unavailable: "error",
} as const;

/**
 * Source control settings: the version-control and hosting tools the server
 * has, and whether each is signed in (`server.discoverSourceControl`).
 */
export function sourceControlSection(host: SectionHost): SettingsSection {
  let discovery: SourceControlDiscoveryResult | null = null;
  let error: string | null = null;
  let generation = 0;

  const scan = () => {
    const asked = ++generation;
    void host.track(
      host.client.discoverSourceControl().then(
        (result) => {
          if (asked !== generation) return;
          discovery = result;
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

  return {
    id: "sourceControl",
    commands: () => [
      {
        id: "section.sourceControl",
        title: "Source control settings",
        keywords: "git github gitlab hosting tools sign in",
        action: "section.open",
        payload: { id: "sourceControl" },
      },
    ],
    open: () => {
      discovery = null;
      error = null;
      scan();
    },
    close: () => {
      generation += 1;
    },
    page: () => {
      const items: SectionItem[] = [];
      if (error !== null) {
        items.push({ kind: "note", text: "Could not scan the server environment", tone: "error" });
        items.push({ kind: "note", text: error });
      } else if (discovery === null) {
        items.push({ kind: "note", text: "Scanning the server environment…" });
      } else {
        const rows = toolRows(discovery);
        if (rows.length === 0) {
          items.push({
            kind: "note",
            text: "Nothing detected yet. Install Git on the server, then rescan.",
          });
        }
        for (const row of rows) {
          items.push({
            kind: "row",
            id: `tool-${row.label}`,
            label: row.label,
            value: row.detail === "" ? row.state : `${row.state} · ${row.detail}`,
            tone: TONE[row.state],
          });
        }
      }
      items.push({ kind: "blank" });
      items.push({ kind: "row", id: "rescan", label: "Rescan Git and hosting tools", run: scan });
      return { title: "source control", items };
    },
  };
}
