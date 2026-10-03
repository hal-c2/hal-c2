import type { ProjectScript, ThreadId } from "@hal-c2/contracts";
import { createComputed, createRoot } from "opentui-qml";

import { plainText, type StyledText } from "../styledText.ts";
import { errorText, payloadField, type Feature, type FeatureKit } from "./kit.ts";

const URL_IN_OUTPUT = /https?:\/\/[^\s"'<>)\]]+/g;

const slug = (text: string) =>
  text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");

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

  const project = () => {
    const current = store.getState();
    const selection = current.selection;
    const id =
      selection?.kind === "project"
        ? selection.id
        : selection?.kind === "thread"
          ? (current.shell?.threads.find((thread) => thread.id === selection.id)?.projectId ?? null)
          : current.projectScopeId;
    return current.shell?.projects.find((candidate) => candidate.id === id) ?? null;
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

  const remove = () => {
    const current = project();
    if (!current) return;
    const threads = (store.getState().shell?.threads ?? []).filter(
      (thread) => thread.projectId === current.id,
    ).length;
    kit.menu({
      title: `remove ${current.title}?`,
      options: [
        { label: `Keep ${current.title}`, description: "Change nothing.", value: "keep" },
        {
          label: `Remove ${current.title}`,
          description: `Its ${threads} thread${threads === 1 ? " goes" : "s go"} too; ${current.workspaceRoot} stays on disk.`,
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
            (error: unknown) => kit.status(`Remove failed: ${errorText(error)}`, "error"),
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
    kit.dispatch("terminal.open");
    kit.dispatch("terminal.input", { data: `${script.command}\r` });
    if (script.autoOpenPreview === true && script.previewUrl) {
      awaitingUrls = [...awaitingUrls, { threadId: workspace.threadId, url: script.previewUrl }];
    }
    kit.status(`Running ${script.name} in the terminal.`, "success");
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

  /** Name, then command: an existing name is edited, a new one added. */
  const editScript = () => {
    const current = project();
    if (!current) return;
    kit.ask({
      label: "script name",
      placeholder: "A new name adds a script, an existing one edits it",
      onSubmit: (name) => {
        if (name === "") return;
        const existing = scripts().find(
          (script) => script.name.toLowerCase() === name.toLowerCase(),
        );
        kit.ask({
          label: `command for ${name}`,
          value: existing?.command ?? "",
          placeholder: "The command to run, like bun run build",
          onSubmit: (command) => {
            if (command === "") {
              kit.status("A script needs a command.", "error");
              return;
            }
            const next: ProjectScript[] = existing
              ? scripts().map((script) =>
                  script.id === existing.id ? { ...script, command: command as never } : script,
                )
              : [
                  ...scripts(),
                  {
                    id: (slug(name) || `script-${scripts().length + 1}`) as never,
                    name: name as never,
                    command: command as never,
                    icon: "play",
                    runOnWorktreeCreate: false,
                  },
                ];
            void kit.track(
              client.updateProject(current.id, { scripts: next }).then(
                () => kit.status(`${existing ? "Updated" : "Added"} ${name}.`, "success"),
                (error: unknown) =>
                  kit.status(`Could not save ${name}: ${errorText(error)}`, "error"),
              ),
            );
          },
        });
      },
    });
  };

  // --- previews --------------------------------------------------------------

  const terminalText = () => {
    const terminal = kit.state.get("terminal") as { lines?: ReadonlyArray<StyledText> } | undefined;
    return (terminal?.lines ?? []).map((line) => plainText(line).trimEnd()).join("\n");
  };
  const announcedUrls = () => [...new Set(terminalText().match(URL_IN_OUTPUT) ?? [])];

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
        const request =
          choice === "open"
            ? client.openPreview(threadId, url).then(() => `Preview opened: ${url}`)
            : choice === "refresh"
              ? client.refreshPreview(threadId, tabId!).then(() => `Preview refreshed: ${url}`)
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
              ? [{ url: session.navStatus.url as string, tabId: session.tabId as string }]
              : [],
          );
          const announced = announcedUrls().filter(
            (url) => !open.some((session) => session.url === url),
          );
          if (open.length + announced.length === 0) {
            kit.status("No previews: nothing is open and the terminal shows no URL.", "info");
            return;
          }
          kit.menu({
            title: "previews",
            searchable: true,
            options: [
              ...open.map((session) => ({
                label: session.url,
                description: "open preview",
                value: JSON.stringify(session),
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
        case "project.remove":
          remove();
          return true;
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
        case "script.edit":
          editScript();
          return true;
        case "previews.open":
          openPreviews();
          return true;
        default:
          return false;
      }
    },
  };
}
