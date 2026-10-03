import type { PreviewSessionSnapshot, ProjectScript, ThreadId } from "@hal-c2/contracts";
import { createComputed, createRoot } from "opentui-qml";

import { plainText, type StyledText } from "../styledText.ts";
import { errorText, payloadField, type Feature, type FeatureKit } from "./kit.ts";

const URL_IN_OUTPUT = /https?:\/\/[^\s"'<>)\]]+/g;

/**
 * The open thread's project from the terminal: rename it, remove it, run its
 * scripts in the thread's terminal, and the preview links it serves (the
 * server's open previews and the URLs its terminal has printed).
 */
export function createWorkspaceFeature(kit: FeatureKit): Feature {
  const { client, store } = kit;
  // The script run last in each project is offered first, as in the other clients.
  const lastRun = new Map<string, string>();
  // Scripts that open their URL as a preview once the terminal shows it.
  let awaitingUrls: Array<{ readonly threadId: string; readonly url: string }> = [];

  /** The open thread's project, else the list's scope, else the only project there is. */
  const project = () => {
    const current = store.getState();
    const selection = current.selection;
    const projects = current.shell?.projects ?? [];
    const id =
      selection?.kind === "project"
        ? selection.id
        : selection?.kind === "thread"
          ? (current.shell?.threads.find((thread) => thread.id === selection.id)?.projectId ?? null)
          : current.projectScopeId;
    return (
      projects.find((candidate) => candidate.id === id) ??
      (id === null && projects.length === 1 ? projects[0]! : null)
    );
  };
  const scripts = (): ReadonlyArray<ProjectScript> => project()?.scripts ?? [];
  /** The script the user ran last here, else the project's first. */
  const preferred = () => {
    const current = project();
    const all = scripts();
    return all.find((script) => script.id === lastRun.get(current?.id ?? "")) ?? all[0] ?? null;
  };

  // --- project ---------------------------------------------------------------

  const rename = () => {
    const current = project();
    if (!current) return;
    kit.ask({
      label: "project name",
      value: current.title,
      onSubmit: (title) => {
        if (title === "" || title === current.title) return;
        void kit.track(
          client.updateProject(current.id, { title }).then(
            () => kit.status(`Project renamed to ${title}.`, "success"),
            (error: unknown) => kit.status(`Rename failed: ${errorText(error)}`, "error"),
          ),
        );
      },
    });
  };

  /** Ask, then remove `projectId` (the current project without one). */
  const remove = (projectId?: string) => {
    const current =
      projectId === undefined
        ? project()
        : (store.getState().shell?.projects.find((candidate) => candidate.id === projectId) ??
          null);
    if (!current) return;
    const threads = (store.getState().shell?.threads ?? []).filter(
      (thread) => thread.projectId === current.id,
    ).length;
    kit.menu({
      title: `remove ${current.title}? its files on disk are kept`,
      options: [
        { label: `Keep ${current.title}`, description: "Change nothing.", value: "keep" },
        {
          label: `Remove ${current.title}`,
          description:
            threads === 0
              ? "It has no threads."
              : `Clears its ${threads} thread${threads === 1 ? " and its" : "s and their"} conversation history.`,
          value: "remove",
        },
      ],
      onChoose: (choice) => {
        if (choice !== "remove") return;
        void kit.track(
          client.deleteProject(current.id).then(
            () =>
              kit.status(
                `Removed ${current.title}; ${current.workspaceRoot} is untouched.`,
                "success",
              ),
            (error: unknown) =>
              kit.status(`Failed to remove project: ${errorText(error)}`, "error"),
          ),
        );
      },
    });
  };

  // --- scripts ---------------------------------------------------------------

  const run = (script: ProjectScript) => {
    const workspace = kit.workspace();
    const current = project();
    if (!workspace || !current) {
      kit.status("Open a thread to run a script in its terminal.", "error");
      return;
    }
    lastRun.set(current.id, script.id);
    // One runner for the palette, the projects page and a script's shortcut (terminalState.ts).
    kit.dispatch("project.action.run", { projectId: current.id, actionId: script.id });
    if (script.autoOpenPreview === true && script.previewUrl) {
      awaitingUrls = [...awaitingUrls, { threadId: workspace.threadId, url: script.previewUrl }];
    }
    kit.commandsChanged();
  };

  const pickScript = () => {
    const all = scripts();
    if (all.length === 0) {
      kit.status("This project has no scripts; add one from the palette.", "info");
      return;
    }
    kit.menu({
      title: "scripts",
      searchable: true,
      options: all.map((script) => ({
        label: script.name,
        description: script.command,
        value: script.id,
      })),
      index: Math.max(
        0,
        all.findIndex((script) => script.id === preferred()?.id),
      ),
      onChoose: (id) => {
        const script = scripts().find((candidate) => candidate.id === id);
        if (script) run(script);
      },
    });
  };

  // --- previews --------------------------------------------------------------

  const terminalText = () => {
    const terminal = kit.state.get("terminal") as { lines?: ReadonlyArray<StyledText> } | undefined;
    return (terminal?.lines ?? []).map((line) => plainText(line).trimEnd()).join("\n");
  };
  const announcedUrls = () => [...new Set(terminalText().match(URL_IN_OUTPUT) ?? [])];

  /** Why a preview's page did not load, or null when it did (or is still loading). */
  const loadFailure = (session: PreviewSessionSnapshot | undefined): string | null =>
    session?.navStatus._tag === "LoadFailed"
      ? session.navStatus.description || `error ${session.navStatus.code}`
      : null;

  const previewActions = (threadId: ThreadId, url: string, tabId: string | null) => {
    kit.menu({
      title: url,
      options: [
        ...(tabId === null
          ? [
              {
                label: "Open as a preview",
                description: "The other clients show it in their preview pane.",
                value: "open",
              },
            ]
          : []),
        { label: "Copy link", description: "To open in your own browser.", value: "copy" },
        ...(tabId !== null
          ? [
              { label: "Refresh", description: "Load the page again.", value: "refresh" },
              { label: "Close preview", description: "Remove it from the list.", value: "close" },
            ]
          : []),
      ],
      onChoose: (choice) => {
        if (choice === "copy") {
          const copied = kit.copy(url);
          kit.status(
            copied ? "Link copied." : "This terminal has no clipboard access.",
            copied ? "success" : "error",
          );
          return;
        }
        if (choice === "refresh") {
          // The page is loaded where the MC shows it; what it found is read back.
          void kit.track(
            client
              .refreshPreview(threadId, tabId!)
              .then(() => client.listPreviews(threadId))
              .then(
                (sessions) => {
                  const failure = loadFailure(sessions.find((session) => session.tabId === tabId));
                  if (failure) kit.status(`Preview unreachable: ${url} (${failure})`, "error");
                  else kit.status(`Preview refreshed: ${url}`, "success");
                },
                (error: unknown) => kit.status(`Preview failed: ${errorText(error)}`, "error"),
              ),
          );
          return;
        }
        const request =
          choice === "open"
            ? client.openPreview(threadId, url).then(() => `Preview opened: ${url}`)
            : client.closePreview(threadId, tabId!).then(() => `Preview closed: ${url}`);
        void kit.track(
          request.then(
            (message) => kit.status(message, "success"),
            (error: unknown) => kit.status(`Preview failed: ${errorText(error)}`, "error"),
          ),
        );
      },
    });
  };

  const openPreviews = () => {
    const workspace = kit.workspace();
    if (!workspace) return;
    const threadId = workspace.threadId as ThreadId;
    void kit.track(
      client.listPreviews(threadId).then(
        (sessions) => {
          const open = sessions.flatMap((session) =>
            "url" in session.navStatus
              ? [
                  {
                    url: session.navStatus.url as string,
                    tabId: session.tabId as string,
                    failure: loadFailure(session),
                  },
                ]
              : [],
          );
          const listed = new Set(open.map((session) => session.url));
          // The addresses the project's scripts are set to serve, then what the terminal printed.
          const configured = scripts().flatMap((script) =>
            script.previewUrl && !listed.has(script.previewUrl)
              ? [{ url: script.previewUrl, name: script.name }]
              : [],
          );
          for (const entry of configured) listed.add(entry.url);
          const announced = announcedUrls().filter((url) => !listed.has(url));
          if (open.length + configured.length + announced.length === 0) {
            kit.status("No previews: nothing is open and the terminal shows no URL.", "info");
            return;
          }
          kit.menu({
            title: "previews",
            searchable: true,
            options: [
              ...open.map((session) => ({
                label: session.url,
                description: session.failure
                  ? `open preview · unreachable: ${session.failure}`
                  : "open preview",
                value: JSON.stringify({ url: session.url, tabId: session.tabId }),
              })),
              ...configured.map((entry) => ({
                label: entry.url,
                description: `configured for ${entry.name}`,
                value: JSON.stringify({ url: entry.url, tabId: null }),
              })),
              ...announced.map((url) => ({
                label: url,
                description: "seen in the terminal",
                value: JSON.stringify({ url, tabId: null }),
              })),
            ],
            onChoose: (value) => {
              const picked = JSON.parse(value) as { url: string; tabId: string | null };
              previewActions(threadId, picked.url, picked.tabId);
            },
          });
        },
        (error: unknown) => kit.status(`Could not list previews: ${errorText(error)}`, "error"),
      ),
    );
  };

  // A script set to open its URL: once the terminal prints it, it becomes a preview.
  const dispose = createRoot((disposeRoot) => {
    createComputed(() => {
      kit.state.get("terminal");
      if (awaitingUrls.length === 0) return;
      const shown = terminalText();
      const ready = awaitingUrls.filter((entry) => shown.includes(entry.url));
      if (ready.length === 0) return;
      awaitingUrls = awaitingUrls.filter((entry) => !ready.includes(entry));
      for (const entry of ready) {
        void kit.track(
          client.openPreview(entry.threadId as ThreadId, entry.url).then(
            () => kit.status(`Preview opened: ${entry.url}`, "success"),
            (error: unknown) => kit.status(`Preview failed: ${errorText(error)}`, "error"),
          ),
        );
      }
    });
    return disposeRoot;
  });

  return {
    dispose,
    commands: () => {
      const current = project();
      if (!current) return [];
      const first = preferred();
      return [
        ...(first
          ? [
              {
                id: "script.run",
                title: `Run ${first.name}`,
                keywords: `project script ${first.command}`,
                action: "script.run",
              },
            ]
          : []),
        ...(scripts().length > 1
          ? [
              {
                id: "script.pick",
                title: "Run a project script…",
                keywords: scripts()
                  .map((script) => script.name)
                  .join(" "),
                action: "script.pick",
              },
            ]
          : []),
        {
          id: "script.edit",
          title: "Add or edit a project script…",
          keywords: "action command",
          action: "script.edit",
        },
        ...(kit.workspace()
          ? [
              {
                id: "previews.open",
                title: "Previews",
                keywords: "url dev server browser link localhost",
                action: "previews.open",
              },
            ]
          : []),
        {
          id: "project.rename",
          title: `Rename project ${current.title}…`,
          keywords: "title",
          action: "project.rename",
        },
        {
          id: "project.remove",
          title: `Remove project ${current.title}…`,
          keywords: "delete forget",
          action: "project.remove",
        },
      ];
    },
    dispatch: (action, payload) => {
      switch (action) {
        case "project.rename":
          rename();
          return true;
        case "project.remove": {
          const id = payloadField(payload, "projectId");
          remove(typeof id === "string" ? id : undefined);
          return true;
        }
        case "script.run": {
          const id = payloadField(payload, "id");
          const script =
            typeof id === "string"
              ? scripts().find((candidate) => candidate.id === id)
              : preferred();
          if (script) run(script);
          else pickScript();
          return true;
        }
        case "script.pick":
          pickScript();
          return true;
        case "script.edit": {
          // The project's page holds its scripts: add, edit, delete, import from hal-c2.json.
          const current = project();
          if (current) kit.dispatch("section.open", { id: "projects", projectId: current.id });
          return true;
        }
        case "previews.open":
          openPreviews();
          return true;
        default:
          return false;
      }
    },
  };
}
