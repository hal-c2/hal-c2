import type { HalC2ProjectFile, ProjectScript, ProjectScriptIcon } from "@hal-c2/contracts";

import {
  importableProjectActions,
  nextProjectActionId,
  PROJECT_ACTION_ICONS,
  projectActionFromFile,
  readProjectFile,
  validateProjectAction,
} from "../../projectActions.ts";
import type { PaletteCommand } from "../paletteState.ts";
import type {
  SectionHost,
  SectionItem,
  SectionPage,
  SettingsSection,
} from "../settingsSections.ts";
import { errorText, plural } from "./shared.ts";

type ShellProject = NonNullable<
  ReturnType<SectionHost["store"]["getState"]>["shell"]
>["projects"][number];

type View =
  | { readonly kind: "list" }
  | { readonly kind: "project"; readonly projectId: string }
  | { readonly kind: "action"; readonly projectId: string; readonly actionId: string }
  | {
      readonly kind: "newAction";
      readonly projectId: string;
      name: string;
      command: string;
      icon: ProjectScriptIcon;
      problem: string | null;
    };

const ENV_MODE_LABEL = { worktree: "New worktree", local: "Project folder" } as const;

/** Run the row's project action in the open thread's terminal (`project.action.run`). */
export const RUN_PROJECT_ACTION = "project.action.run";

/**
 * Projects: each one's folder, where its new threads start, its actions (named
 * commands, run in the open thread's terminal) with what its hal-c2.json
 * offers to import, and removing it from HAL-C2. Changes go to the MC as
 * `projects.mutate`; the page follows the shell snapshot.
 */
export function projectsSection(
  host: SectionHost,
  options: {
    /** Run an action in the open thread's terminal; false when no thread of the project is open. */
    readonly runAction: (projectId: string, script: ProjectScript) => boolean;
  },
): SettingsSection {
  const { client, store } = host;
  let view: View = { kind: "list" };
  let unsubscribe: (() => void) | null = null;
  // Each project's hal-c2.json as last read (null: none, or not valid).
  const files = new Map<string, HalC2ProjectFile | null>();
  const reading = new Set<string>();

  const projects = (): ReadonlyArray<ShellProject> => store.getState().shell?.projects ?? [];
  const project = (id: string) => projects().find((candidate) => candidate.id === id) ?? null;
  const scriptsOf = (target: ShellProject): ReadonlyArray<ProjectScript> => target.scripts ?? [];
  const threadCount = (id: string) =>
    (store.getState().shell?.threads ?? []).filter((thread) => thread.projectId === id).length;

  /** The project the user is in: the open thread's, the list's scope, or the only one. */
  const currentProject = (): ShellProject | null => {
    const state = store.getState();
    const selection = state.selection;
    const threadProject =
      selection?.kind === "thread"
        ? state.shell?.threads.find((thread) => thread.id === selection.id)?.projectId
        : selection?.kind === "project"
          ? selection.id
          : null;
    const id = threadProject ?? state.projectScopeId;
    if (id) return project(id);
    return projects().length === 1 ? projects()[0]! : null;
  };

  const readFile = (target: ShellProject) => {
    if (reading.has(target.id)) return;
    reading.add(target.id);
    void host.track(
      readProjectFile(client.readFile, target.workspaceRoot).then((file) => {
        reading.delete(target.id);
        files.set(target.id, file);
        host.refresh();
      }),
    );
  };

  const mutate = (payload: Record<string, unknown>) =>
    host.track(client.mcCall("projects.mutate", payload));

  const saveScripts = (
    target: ShellProject,
    scripts: ReadonlyArray<ProjectScript>,
    done: string,
  ) => {
    void mutate({ type: "project.update", projectId: target.id, scripts }).then(
      () => {
        host.status(done, "success");
        host.refresh();
      },
      (cause: unknown) => host.status(`Could not save the action: ${errorText(cause)}`, "error"),
    );
  };

  const askRemoval = (target: ShellProject) => {
    const count = threadCount(target.id);
    host.confirm(
      `Remove ${target.title} from HAL-C2? ${
        count > 0
          ? `Its ${plural(count, "thread")} and their conversation history will be cleared permanently.`
          : "It has no threads."
      } The files on disk are kept.`,
      () => {
        void mutate({ type: "project.delete", projectId: target.id, force: true }).then(
          () => {
            host.status(`Removed ${target.title}.`, "success");
            view = { kind: "list" };
            host.refresh();
          },
          (cause: unknown) => host.status(`Failed to remove project: ${errorText(cause)}`, "error"),
        );
      },
    );
  };

  const run = (target: ShellProject, script: ProjectScript) => {
    if (!options.runAction(target.id, script)) {
      host.status(`Open a thread in ${target.title} to run its actions.`, "error");
    }
  };

  const importActions = (target: ShellProject, names: ReadonlyArray<string> | null) => {
    const offered = importableProjectActions(
      files.get(target.id)?.scripts ?? [],
      scriptsOf(target),
    );
    const chosen = names === null ? offered : offered.filter((entry) => names.includes(entry.name));
    if (chosen.length === 0) return;
    const scripts = [...scriptsOf(target)];
    for (const entry of chosen) {
      scripts.push(
        projectActionFromFile(
          nextProjectActionId(
            entry.name,
            scripts.map((script) => script.id),
          ),
          entry,
        ),
      );
    }
    saveScripts(
      target,
      scripts,
      chosen.length === 1
        ? `Imported ${chosen[0]!.name}.`
        : `Imported ${plural(chosen.length, "action")}.`,
    );
  };

  const listPage = (): SectionPage => {
    const items: SectionItem[] = [];
    if (projects().length === 0) {
      items.push({ kind: "note", text: "No projects yet. Add one from the command palette." });
    }
    for (const entry of projects()) {
      items.push({
        kind: "row",
        id: `project-${entry.id}`,
        label: entry.title,
        value: entry.workspaceRoot,
        clip: true,
        run: () => {
          view = { kind: "project", projectId: entry.id };
          readFile(entry);
          host.refresh();
        },
      });
    }
    return { title: "projects", items };
  };

  const workspaceRow = (target: ShellProject): SectionItem => {
    const own = target.defaultThreadEnvMode ?? null;
    const fromFile = files.get(target.id)?.defaultThreadEnvMode ?? null;
    const order = [null, "worktree", "local"] as const;
    return {
      kind: "row",
      id: "workspace",
      label: "New threads start in",
      value:
        own !== null
          ? ENV_MODE_LABEL[own]
          : fromFile !== null
            ? `${ENV_MODE_LABEL[fromFile]} (from hal-c2.json)`
            : "The environment's default",
      run: () => {
        const next = order[(order.indexOf(own) + 1) % order.length] ?? null;
        void mutate({
          type: "project.update",
          projectId: target.id,
          defaultThreadEnvMode: next,
        }).then(
          () => host.refresh(),
          (cause: unknown) =>
            host.status(`Could not save the setting: ${errorText(cause)}`, "error"),
        );
      },
    };
  };

  const projectPage = (target: ShellProject): SectionPage => {
    const items: SectionItem[] = [
      { kind: "row", id: "folder", label: "Folder", value: target.workspaceRoot },
      workspaceRow(target),
      { kind: "blank" },
      { kind: "heading", text: "Actions" },
    ];
    const scripts = scriptsOf(target);
    if (scripts.length === 0) {
      items.push({
        kind: "note",
        text: "No actions. An action is a named command, such as starting the dev server.",
      });
    }
    for (const script of scripts) {
      items.push({
        kind: "row",
        id: `action-${script.id}`,
        label: script.name,
        value: script.runOnWorktreeCreate ? `${script.command} · setup script` : script.command,
        run: () => {
          view = { kind: "action", projectId: target.id, actionId: script.id };
          host.refresh();
        },
      });
    }
    items.push({
      kind: "row",
      id: "add-action",
      label: "+ Add an action",
      tone: "accent",
      run: () => {
        view = {
          kind: "newAction",
          projectId: target.id,
          name: "",
          command: "",
          icon: "play",
          problem: null,
        };
        host.refresh();
        host.select("new-name");
      },
    });
    const offered = importableProjectActions(files.get(target.id)?.scripts ?? [], scripts);
    if (offered.length > 0) {
      items.push({ kind: "blank" });
      items.push({ kind: "heading", text: "From hal-c2.json" });
      for (const entry of offered) {
        items.push({
          kind: "row",
          id: `import-${entry.name}`,
          label: `Import ${entry.name}`,
          value: entry.command,
          run: () => importActions(target, [entry.name]),
        });
      }
      if (offered.length > 1) {
        items.push({
          kind: "row",
          id: "import-all",
          label: `Import all ${offered.length} actions`,
          tone: "accent",
          run: () => importActions(target, null),
        });
      }
    }
    items.push({ kind: "blank" });
    items.push({
      kind: "row",
      id: "remove",
      label: "Remove project…",
      tone: "error",
      run: () => askRemoval(target),
    });
    return { title: `project · ${target.title}`, items };
  };

  const actionPage = (target: ShellProject, script: ProjectScript): SectionPage => {
    const change = (patch: Partial<ProjectScript>, done: string) =>
      saveScripts(
        target,
        scriptsOf(target).map((entry) => (entry.id === script.id ? { ...entry, ...patch } : entry)),
        done,
      );
    const edit = (field: "name" | "command", label: string) =>
      host.ask({ label, value: script[field] }, (text) => {
        const problem = validateProjectAction({ ...script, [field]: text });
        if (problem) {
          host.status(problem, "error");
          return;
        }
        if (text !== script[field]) change({ [field]: text }, "Action saved.");
      });
    return {
      title: `project · ${target.title} · ${script.name}`,
      items: [
        {
          kind: "row",
          id: "run",
          label: "Run",
          tone: "accent",
          value: "in the open thread's terminal",
          run: () => run(target, script),
        },
        { kind: "blank" },
        {
          kind: "row",
          id: "name",
          label: "Name",
          value: script.name,
          run: () => edit("name", "Name"),
        },
        {
          kind: "row",
          id: "command",
          label: "Command",
          value: script.command,
          run: () => edit("command", "Command"),
        },
        {
          kind: "row",
          id: "icon",
          label: "Icon",
          value: script.icon,
          run: () =>
            change(
              {
                icon: PROJECT_ACTION_ICONS[
                  (PROJECT_ACTION_ICONS.indexOf(script.icon) + 1) % PROJECT_ACTION_ICONS.length
                ]!,
              },
              "Action saved.",
            ),
        },
        { kind: "blank" },
        {
          kind: "row",
          id: "delete",
          label: "Delete action…",
          tone: "error",
          run: () =>
            host.confirm(`Delete action "${script.name}"? This cannot be undone.`, () => {
              view = { kind: "project", projectId: target.id };
              saveScripts(
                target,
                scriptsOf(target).filter((entry) => entry.id !== script.id),
                `Deleted ${script.name}.`,
              );
            }),
        },
      ],
    };
  };

  const newActionPage = (
    target: ShellProject,
    form: Extract<View, { kind: "newAction" }>,
  ): SectionPage => {
    const text = (field: "name" | "command", label: string, placeholder: string): SectionItem => ({
      kind: "row",
      id: `new-${field}`,
      label,
      value: form[field] === "" ? "—" : form[field],
      run: () =>
        host.ask({ label, value: form[field], placeholder }, (next) => {
          form[field] = next;
          form.problem = null;
          host.refresh();
        }),
    });
    return {
      title: `project · ${target.title} · new action`,
      items: [
        ...(form.problem ? [{ kind: "note", text: form.problem, tone: "error" } as const] : []),
        text("name", "Name", "Dev"),
        text("command", "Command", "bun dev"),
        {
          kind: "row",
          id: "new-icon",
          label: "Icon",
          value: form.icon,
          run: () => {
            form.icon =
              PROJECT_ACTION_ICONS[
                (PROJECT_ACTION_ICONS.indexOf(form.icon) + 1) % PROJECT_ACTION_ICONS.length
              ]!;
            host.refresh();
          },
        },
        { kind: "blank" },
        {
          kind: "row",
          id: "new-add",
          label: "Add action",
          tone: "accent",
          run: () => {
            const problem = validateProjectAction(form);
            if (problem) {
              form.problem = problem;
              host.status(problem, "error");
              host.refresh();
              return;
            }
            const scripts = scriptsOf(target);
            view = { kind: "project", projectId: target.id };
            saveScripts(
              target,
              [
                ...scripts,
                {
                  id: nextProjectActionId(
                    form.name,
                    scripts.map((script) => script.id),
                  ),
                  name: form.name.trim(),
                  command: form.command.trim(),
                  icon: form.icon,
                  runOnWorktreeCreate: false,
                } as ProjectScript,
              ],
              `Added ${form.name.trim()}.`,
            );
            host.refresh();
          },
        },
      ],
    };
  };

  const commands = (): PaletteCommand[] => {
    const list: PaletteCommand[] = [
      {
        id: "section.projects",
        title: "Projects",
        keywords: "project settings actions scripts remove folder",
        action: "section.open",
        payload: { id: "projects" },
      },
    ];
    const current = currentProject();
    if (!current) return list;
    list.push({
      id: "section.projects.current",
      title: `Project actions: ${current.title}`,
      keywords: "project settings scripts commands hal-c2.json import",
      action: "section.open",
      payload: { id: "projects", projectId: current.id },
    });
    for (const script of scriptsOf(current)) {
      list.push({
        id: `project.action.${script.id}`,
        title: `Run action: ${script.name}`,
        keywords: `script ${script.command}`,
        action: RUN_PROJECT_ACTION,
        payload: { projectId: current.id, actionId: script.id },
      });
    }
    list.push({
      id: "section.projects.remove",
      title: `Remove project ${current.title}…`,
      keywords: "delete project",
      action: "section.open",
      payload: { id: "projects", projectId: current.id, remove: true },
    });
    return list;
  };

  return {
    id: "projects",
    commands,
    open: (payload) => {
      const wanted = payload as { readonly projectId?: unknown; readonly remove?: unknown };
      const target = typeof wanted?.projectId === "string" ? project(wanted.projectId) : null;
      view = target ? { kind: "project", projectId: target.id } : { kind: "list" };
      unsubscribe ??= store.subscribe(() => host.refresh());
      if (target) {
        files.delete(target.id);
        readFile(target);
        if (wanted.remove === true) {
          askRemoval(target);
          host.select("remove");
        }
      }
    },
    close: () => {
      unsubscribe?.();
      unsubscribe = null;
      files.clear();
    },
    back: () => {
      if (view.kind === "list") return false;
      view =
        view.kind === "project" ? { kind: "list" } : { kind: "project", projectId: view.projectId };
      return true;
    },
    page: () => {
      if (view.kind === "list") return listPage();
      const target = project(view.projectId);
      // The project went away (removed here or by another client).
      if (!target) {
        view = { kind: "list" };
        return listPage();
      }
      if (view.kind === "newAction") return newActionPage(target, view);
      if (view.kind === "action") {
        const actionId = view.actionId;
        const script = scriptsOf(target).find((entry) => entry.id === actionId);
        if (script) return actionPage(target, script);
        view = { kind: "project", projectId: target.id };
      }
      return projectPage(target);
    },
    dispatch: (action, payload) => {
      if (action !== RUN_PROJECT_ACTION) return false;
      const wanted = payload as { readonly projectId?: unknown; readonly actionId?: unknown };
      const target = typeof wanted?.projectId === "string" ? project(wanted.projectId) : null;
      const script = target
        ? scriptsOf(target).find((entry) => entry.id === wanted.actionId)
        : undefined;
      if (target && script) run(target, script);
      return true;
    },
  };
}
