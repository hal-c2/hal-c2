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

type Flags = { readonly drain?: ReadonlyArray<string>; readonly force?: boolean };

/**
 * Where this machine's code reviews that need a sandbox go while it can't run one:
 * the status's `sandboxMachines`, the cluster's machines that can (absent from older
 * MCs).
 */
const handoff = (status: ServerOpenShellStatus) => {
  const machines = [...(status.sandboxMachines ?? [])];
  const last = machines.pop();
  if (last === undefined) {
    return "Code reviews that need a sandbox fail here until this machine or another of your cluster can run them.";
  }
  const named = machines.length === 0 ? last : `${machines.join(", ")} and ${last}`;
  return `Code reviews that need a sandbox go to ${named}.`;
};

const reviews = (count: number) => `${count} review${count === 1 ? "" : "s"}`;

/**
 * Review sandboxes: whether this environment can run code reviews in an
 * OpenShell sandbox and, when it can't, what is wrong and what to do, from the
 * MC's `server.getOpenShellStatus`, read when the page opens, on Refresh and
 * after each operation. The actions the status offers (Install, Check, Rotate
 * certificates, Uninstall, …) run with `server.runOpenShellOperation`; their
 * steps and outcome come from the openShell shape, so an operation another
 * device started shows here too. An operation that would stop this MC's
 * reviews asks first, and runs again on a yes with `drain` naming the reviews it
 * asked about (or `force`); when others run by then the MC asks again.
 */
export function sandboxesSection(host: SectionHost): SettingsSection {
  let status: ServerOpenShellStatus | null = null;
  let error: string | null = null;
  let loading = false;
  let generation = 0;
  let operation: OpenShellOperationState | null = null;
  // The operation this page asked for, until its outcome arrives.
  let asked: ServerOpenShellOperation | null = null;
  // A run this page sent that the MC has not refused and no frame of has landed
  // since its reply. The actions stay off until then: a second press in between
  // would be refused as busy, and that refusal would forget what this page asked
  // for.
  let starting = false;
  // The run's number, from its reply: null until it lands.
  let awaited: number | null = null;
  // The latest run asked for, so an older one's reply is not taken for it.
  let request = 0;
  let refusal: string | null = null;
  // The last frame's number, once one of this opening has landed.
  let last: number | null = null;
  // The ended run the status was last read for: the one the shape's first frame
  // showed ended (the read the page opened with covers it), then each one after.
  let known: number | null = null;
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
    awaited = null;
    refusal = null;
    const sent = ++request;
    void host.track(
      host.client
        .mcCall<OpenShellOperationState>("server.runOpenShellOperation", {
          operation: name,
          ...flags,
        })
        .then(
          (reply) => {
            // The reply names the run; a frame of it that came first settles it now.
            if (sent !== request || !starting) return;
            awaited = reply.run;
            if (operation !== null && operation.run >= awaited) settle(operation);
          },
          (cause: unknown) => {
            // Only the latest press on this opening of the page: one from before
            // the page closed, or before a later press, is forgotten.
            if (sent !== request) return;
            starting = false;
            asked = null;
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
    const drain = result.drain;
    if (
      (result.code === "sandboxes-running" || result.code === "sandboxes-changed") &&
      drain !== null &&
      drain.length > 0
    ) {
      // The yes names what it was asked about: the MC deletes no other review.
      host.confirm(`Stop ${reviews(drain.length)} and go ahead? ${result.message}`, () =>
        run(name, { drain }),
      );
    } else if (result.code === "sandboxes-unknown") {
      host.confirm(`Go ahead anyway? ${result.message}`, () => run(name, { force: true }));
    }
  };

  const follow = (next: OpenShellOperationState) => {
    // The MC sends a subscription's frames in order, and the first after a
    // reconnect is its state then, so a number below the last frame's is from an
    // MC whose clock went back across a restart (operations.ex's number/1).
    const back = last !== null && next.run < last;
    // The old MC's numbers say nothing of the new one's runs.
    if (back) known = null;
    if (last === null && !next.running) known = next.run;
    last = next.run;
    // A frame from before the run (the shape's first, another device's last) is
    // shown, but neither reopens the actions nor answers the run. Whichever of
    // the reply and the run's frame lands second settles it, so a run that ended
    // while the connection was down settles on the first frame after it.
    if (starting && !back && (awaited === null || next.run < awaited)) {
      operation = next;
      if (!reread(next, false)) host.refresh();
      return;
    }
    settle(next, back);
  };

  // What is installed may have changed once a run ended: the status is read again
  // for each run seen ended, once, whether or not this page saw it run (it may have
  // ended on another device while the connection was down), and for a run this
  // page saw going that went with a restart (`ended`).
  const reread = (next: OpenShellOperationState, ended: boolean) => {
    if (next.running || next.run === known || (next.operation === null && !ended)) return false;
    known = next.run;
    read();
    return true;
  };

  const settle = (next: OpenShellOperationState, back = false) => {
    const ended = busy() && !next.running;
    operation = next;
    starting = false;
    if (
      !next.running &&
      next.result !== null &&
      asked !== null &&
      asked === next.operation &&
      next.run === awaited
    ) {
      asked = null;
      answer(next.operation, next.result);
    } else if (
      asked !== null &&
      awaited !== null &&
      (back || (next.operation === null && next.run > awaited))
    ) {
      // A frame with no operation is from an MC that has run none since it
      // started, and its number is when it started. Above the run's number, it
      // started after the run did: it restarted, and the run's outcome went with
      // the old one (a restart of only its Operations service takes the run back
      // and shows it going on). Whether the run's work got done is unknown, so
      // the words promise no retry. This
      // holds whatever the frame's order: a frame from before the run (the
      // shape's first, one sent before a reconnect) carries a smaller number, as
      // the run's is larger than every number before it. An MC whose clock went
      // back across the restart numbers below the run, and the number going
      // below the last frame's says so instead.
      asked = null;
      refusal = "The MC lost track of the run; check the status before trying again.";
    }
    if (!reread(next, ended)) host.refresh();
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
        { kind: "note", text: handoff(status), tone: "dim" },
        ...problems,
      ];
    }
    if (!status.ready) {
      return [
        { kind: "note", text: "Review sandboxes can't run here yet.", tone: "warning" },
        { kind: "note", text: handoff(status), tone: "dim" },
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
      awaited = null;
      refusal = null;
      last = null;
      known = null;
      unsubscribe?.();
      unsubscribe = host.client.subscribeOpenShellOperation(follow);
      read();
    },
    close: () => {
      generation += 1;
      request += 1;
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
