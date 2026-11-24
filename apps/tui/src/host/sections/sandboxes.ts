import type {
  OpenShellOperationState,
  ServerOpenShellOperation,
  ServerOpenShellStatus,
} from "@hal-c2/contracts";

import type { SectionHost, SectionItem, SettingsSection } from "../settingsSections.ts";
import { errorText } from "./shared.ts";

const MODES: Record<string, string> = {
  managed: "run by this MC",
  external: "a gateway you run",
  foreground: "the dev run",
};

const RUNNING: Record<ServerOpenShellOperation, string> = {
  install: "Installing OpenShell…",
  check: "Checking OpenShell…",
  rotate: "Replacing OpenShell's certificates…",
  uninstall: "Removing OpenShell…",
};

type Flags = { readonly drain?: boolean; readonly force?: boolean };

const reviews = (count: number) => `${count} review${count === 1 ? "" : "s"}`;

/**
 * Review sandboxes: whether this environment can run code reviews in an
 * OpenShell sandbox and, when it can't, what is wrong and what to do, from the
 * MC's `server.getOpenShellStatus`, read when the page opens, on Refresh and
 * after each operation. The actions the status offers (Install, Check, Rotate
 * certificates, Uninstall, …) run with `server.runOpenShellOperation`; their
 * steps and outcome come from the openShell shape, so an operation another
 * device started shows here too. An operation that would stop this MC's
 * reviews asks first, and runs again with `drain` (or `force`) on a yes.
 */
export function sandboxesSection(host: SectionHost): SettingsSection {
  let status: ServerOpenShellStatus | null = null;
  let error: string | null = null;
  let loading = false;
  let generation = 0;
  let operation: OpenShellOperationState | null = null;
  // The operation this page asked for, until its outcome arrives.
  let asked: ServerOpenShellOperation | null = null;
  // A run this page sent that no frame has shown running yet and the MC has not
  // refused. The actions stay off until then: its reply may land before or after that
  // frame, and a second press in between would be refused as busy, and that
  // refusal would forget what this page asked for.
  let starting = false;
  let refusal: string | null = null;
  let unsubscribe: (() => void) | null = null;

  const read = () => {
    const reading = ++generation;
    loading = true;
    void host.track(
      host.client.mcCall<ServerOpenShellStatus>("server.getOpenShellStatus", {}).then(
        (next) => {
          if (reading !== generation) return;
          loading = false;
          status = next;
          error = null;
          host.refresh();
        },
        (cause: unknown) => {
          if (reading !== generation) return;
          loading = false;
          status = null;
          error = errorText(cause);
          host.refresh();
        },
      ),
    );
    host.refresh();
  };

  const busy = () => starting || operation?.running === true;

  const run = (name: ServerOpenShellOperation, flags: Flags = {}) => {
    asked = name;
    starting = true;
    refusal = null;
    void host.track(
      host.client.mcCall("server.runOpenShellOperation", { operation: name, ...flags }).then(
        () => undefined,
        (cause: unknown) => {
          starting = false;
          if (asked === name) asked = null;
          refusal = errorText(cause);
          host.refresh();
        },
      ),
    );
    host.refresh();
  };

  // An outcome this page asked for may need the user's yes to go on.
  const answer = (name: ServerOpenShellOperation, result: OpenShellOperationState["result"]) => {
    if (result === null || result.ok) return;
    if (result.code === "sandboxes-running" && result.sandboxes !== null) {
      host.confirm(`Stop ${reviews(result.sandboxes)} and go ahead? ${result.message}`, () =>
        run(name, { drain: true }),
      );
    } else if (result.code === "sandboxes-unknown") {
      host.confirm(`Go ahead anyway? ${result.message}`, () => run(name, { force: true }));
    }
  };

  const follow = (next: OpenShellOperationState) => {
    // A frame from before the run (the shape's first, another device's last) is
    // shown, but neither reopens the actions nor answers the run.
    if (starting && !(next.running && next.operation === asked)) {
      operation = next;
      host.refresh();
      return;
    }
    const ended = busy() && !next.running;
    operation = next;
    starting = false;
    if (!next.running && next.result !== null && asked !== null && asked === next.operation) {
      asked = null;
      answer(next.operation, next.result);
    }
    // What is installed changed: say so.
    if (ended) read();
    else host.refresh();
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

  // The operation running or last run: what it is doing, then how it went.
  const progress = (): SectionItem[] => {
    const items: SectionItem[] = [];
    if (operation !== null && operation.operation !== null) {
      items.push({ kind: "blank" });
      if (operation.running) {
        items.push({ kind: "note", text: RUNNING[operation.operation], tone: "accent" });
      }
      for (const step of operation.steps) {
        items.push({ kind: "note", text: step, tone: "dim", indent: 2 });
      }
      if (!operation.running && operation.result !== null) {
        items.push({
          kind: "note",
          text: operation.result.message,
          tone: operation.result.ok ? "success" : "error",
        });
      }
    }
    if (refusal !== null) {
      items.push({ kind: "blank" }, { kind: "note", text: refusal, tone: "error" });
    }
    return items;
  };

  const actions = (): SectionItem[] => {
    if (status === null || status.actions.length === 0) return [];
    const rows: SectionItem[] = status.actions.map((action) =>
      status!.canManage && !busy()
        ? {
            kind: "row",
            id: `operation:${action.operation}`,
            label: action.label,
            run: () => {
              if (!busy()) run(action.operation);
            },
          }
        : { kind: "row", id: `operation:${action.operation}`, label: action.label, tone: "dim" },
    );
    if (!status.canManage && status.manageReason !== null) {
      rows.push({ kind: "note", text: status.manageReason, tone: "dim", indent: 2 });
    }
    return [{ kind: "blank" }, ...rows];
  };

  return {
    id: "sandboxes",
    commands: () => [
      {
        id: "section.sandboxes",
        title: "Review sandboxes",
        keywords:
          "openshell sandbox code review gateway podman docker container isolation install uninstall rotate certificates check",
        action: "section.open",
        payload: { id: "sandboxes" },
      },
    ],
    open: () => {
      status = null;
      error = null;
      operation = null;
      asked = null;
      starting = false;
      refusal = null;
      unsubscribe?.();
      unsubscribe = host.client.subscribeOpenShellOperation(follow);
      read();
    },
    close: () => {
      generation += 1;
      unsubscribe?.();
      unsubscribe = null;
    },
    page: () => ({
      title: "review sandboxes",
      items: [
        ...summary(),
        ...progress(),
        ...actions(),
        { kind: "blank" },
        loading
          ? { kind: "row", id: "refresh", label: "Checking…", tone: "dim" }
          : { kind: "row", id: "refresh", label: "Refresh", run: read },
      ],
    }),
  };
}
