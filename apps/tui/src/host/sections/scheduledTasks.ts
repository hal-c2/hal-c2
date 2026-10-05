import {
  MIN_SCHEDULED_TASK_INTERVAL_MS,
  type ModelSelection,
  type ProviderInteractionMode,
  type RuntimeMode,
  type ScheduledTask,
} from "@hal-c2/contracts";

import { RUNTIME_MODE_META } from "../../controls.ts";
import type { ModelOption } from "../../models.ts";
import type { SectionHost, SectionItem, SettingsSection } from "../settingsSections.ts";
import { errorText, type Machine, readMachines } from "./shared.ts";

// Scheduled tasks: a saved prompt the MC sends to a project on a timer. The
// page lists a machine's tasks (all projects or one), and its editor creates
// and changes them. The MC owns the schedule; this only asks it
// (`scheduledTasks.*`) and follows this machine's list as it changes.

export type WorkspaceMode = "root" | "worktree" | "existing_worktree";

/** The editor's fields, as typed: text stays text until the task is saved. */
export interface TaskDraft {
  readonly editingId: string | null;
  readonly title: string;
  readonly prompt: string;
  readonly enabled: boolean;
  readonly scheduleMode: "fixed" | "interval";
  readonly intervalMinutes: string;
  readonly timeOfDay: string;
  /** 0 is Sunday; a fixed-time task runs on at least one day. */
  readonly weekdays: ReadonlyArray<number>;
  readonly projectId: string;
  readonly threadId: string | null;
  readonly workspaceMode: WorkspaceMode;
  readonly baseRef: string;
  readonly startFromOrigin: boolean;
  readonly checkoutPath: string;
  readonly modelSelection: ModelSelection | null;
  readonly runtimeMode: RuntimeMode;
  readonly interactionMode: ProviderInteractionMode;
}

const WEEKDAYS = [1, 2, 3, 4, 5];
const DAY_NAMES = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
/** Monday first, as the editor lists them. */
const DAY_ORDER = [1, 2, 3, 4, 5, 6, 0];
const TIME_OF_DAY = /^([01]?\d|2[0-3]):([0-5]\d)$/;

/** A new task: a new worktree from main fetched from origin, 09:00 on weekdays, full access. */
export function newTaskDraft(input: {
  readonly projectId: string;
  readonly modelSelection: ModelSelection | null;
}): TaskDraft {
  return {
    editingId: null,
    title: "",
    prompt: "",
    enabled: true,
    scheduleMode: "fixed",
    intervalMinutes: "15",
    timeOfDay: "09:00",
    weekdays: WEEKDAYS,
    projectId: input.projectId,
    threadId: null,
    workspaceMode: "worktree",
    baseRef: "main",
    startFromOrigin: true,
    checkoutPath: "",
    modelSelection: input.modelSelection,
    runtimeMode: "full-access",
    interactionMode: "default",
  };
}

export function taskToDraft(task: ScheduledTask): TaskDraft {
  const schedule = task.schedule;
  const workspace = task.workspaceStrategy;
  return {
    editingId: task.id,
    title: task.title,
    prompt: task.prompt,
    enabled: task.enabled,
    scheduleMode: schedule.type === "interval" ? "interval" : "fixed",
    // A task from an older version may run more often than a minute; saving raises it.
    intervalMinutes:
      schedule.type === "interval" ? String(Math.max(1, schedule.everyMs / 60_000)) : "15",
    timeOfDay: schedule.type === "fixed_time" ? schedule.timeOfDay : "09:00",
    weekdays:
      schedule.type === "fixed_time" && schedule.weekdays && schedule.weekdays.length > 0
        ? schedule.weekdays
        : [0, 1, 2, 3, 4, 5, 6],
    projectId: task.projectId,
    threadId: task.threadId ?? null,
    workspaceMode: workspace.type,
    baseRef: workspace.type === "worktree" ? workspace.baseRef : "main",
    startFromOrigin: workspace.type === "worktree" ? (workspace.startFromOrigin ?? false) : true,
    checkoutPath: workspace.type === "existing_worktree" ? workspace.worktreePath : "",
    modelSelection: task.modelSelection,
    runtimeMode: task.runtimeMode,
    interactionMode: task.interactionMode,
  };
}

/** Turn a weekday on or off; the last chosen day stays chosen. */
export function toggleDay(days: ReadonlyArray<number>, day: number): number[] {
  if (!days.includes(day)) return [...days, day];
  return days.length > 1 ? days.filter((chosen) => chosen !== day) : [...days];
}

export type DraftProblem = { readonly title: string; readonly detail: string };

/** The `scheduledTasks.upsert` payload for a draft, or what is wrong with it. */
export function draftToUpsert(
  draft: TaskDraft,
): { readonly input: Record<string, unknown> } | { readonly problem: DraftProblem } {
  const title = draft.title.trim();
  const prompt = draft.prompt.trim();
  if (title === "" || prompt === "" || draft.projectId === "" || draft.modelSelection === null) {
    return {
      problem: {
        title: "Scheduled task is incomplete",
        detail: "Add a title, prompt, project, and model.",
      },
    };
  }
  let schedule: Record<string, unknown>;
  if (draft.scheduleMode === "interval") {
    const minutes = Number(draft.intervalMinutes.trim());
    if (draft.intervalMinutes.trim() === "" || !Number.isFinite(minutes) || minutes < 1) {
      return {
        problem: {
          title: "Invalid interval",
          detail: "Enter an interval of at least one minute.",
        },
      };
    }
    schedule = {
      type: "interval",
      everyMs: Math.max(MIN_SCHEDULED_TASK_INTERVAL_MS, Math.round(minutes * 60_000)),
    };
  } else {
    if (!TIME_OF_DAY.test(draft.timeOfDay.trim())) {
      return {
        problem: {
          title: "Invalid time",
          detail: "Enter the time of day as HH:MM, such as 09:00.",
        },
      };
    }
    const weekdays = draft.weekdays.toSorted((a, b) => a - b);
    schedule = {
      type: "fixed_time",
      timeOfDay: draft.timeOfDay.trim(),
      ...(weekdays.length === 7 ? {} : { weekdays }),
    };
  }
  let workspaceStrategy: Record<string, unknown>;
  if (draft.workspaceMode === "existing_worktree") {
    const path = draft.checkoutPath.trim();
    if (path === "") {
      return {
        problem: {
          title: "Checkout path is required",
          detail: "Enter the path of the checkout to run in.",
        },
      };
    }
    workspaceStrategy = { type: "existing_worktree", worktreePath: path };
  } else if (draft.workspaceMode === "worktree") {
    workspaceStrategy = {
      type: "worktree",
      baseRef: draft.baseRef.trim() || "main",
      startFromOrigin: draft.startFromOrigin,
    };
  } else {
    workspaceStrategy = { type: "root" };
  }
  return {
    input: {
      ...(draft.editingId === null ? {} : { id: draft.editingId, requireExisting: true }),
      title,
      prompt,
      enabled: draft.enabled,
      schedule,
      projectId: draft.projectId,
      threadId: draft.threadId,
      workspaceStrategy,
      modelSelection: draft.modelSelection,
      runtimeMode: draft.runtimeMode,
      interactionMode: draft.interactionMode,
    },
  };
}

const sameDays = (days: ReadonlyArray<number>, other: ReadonlyArray<number>) =>
  days.length === other.length && other.every((day) => days.includes(day));

export function scheduleLabel(schedule: ScheduledTask["schedule"]): string {
  if (schedule.type === "interval") {
    const minutes = schedule.everyMs / 60_000;
    return Number.isInteger(minutes)
      ? `Every ${minutes} min`
      : `Every ${Math.round(schedule.everyMs / 1000)} sec`;
  }
  const days = schedule.weekdays ?? [];
  if (days.length === 0 || days.length === 7) return `${schedule.timeOfDay} every day`;
  if (sameDays(days, WEEKDAYS)) return `${schedule.timeOfDay} on weekdays`;
  return `${schedule.timeOfDay} on ${DAY_ORDER.filter((day) => days.includes(day))
    .map((day) => DAY_NAMES[day]!.slice(0, 3))
    .join(", ")}`;
}

function relative(ms: number): string {
  const minutes = Math.max(1, Math.round(Math.abs(ms) / 60_000));
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `${hours} h`;
  return `${Math.round(hours / 24)} d`;
}

/** When the task runs next: "Paused", "Next run in 3 h", "Not scheduled". */
export function whenLabel(task: ScheduledTask, nowMs: number): string {
  if (!task.enabled) return "Paused";
  const next = task.nextRunAt === null ? Number.NaN : Date.parse(String(task.nextRunAt));
  if (!Number.isFinite(next)) return "Not scheduled";
  return next <= nowMs ? "Next run now" : `Next run in ${relative(next - nowMs)}`;
}

/** How the last run went, as the list badges it. */
export function lastRunLabel(task: ScheduledTask): string {
  switch (task.lastRunStatus) {
    case "failed":
      return "Failed";
    case "running":
      return "Running";
    case "succeeded":
      return "Succeeded";
    default:
      return "Never run";
  }
}

type Listing =
  | { readonly status: "loading" }
  | { readonly status: "ready"; readonly tasks: ReadonlyArray<ScheduledTask> }
  | { readonly status: "disconnected"; readonly message: string }
  | { readonly status: "error"; readonly message: string };

interface Editor {
  /** Tells a save that was answered late whether its editor is still the one open. */
  readonly seq: number;
  readonly machineId: string;
  draft: TaskDraft;
  saving: boolean;
  problem: DraftProblem | null;
  /** The task was deleted elsewhere while it was open. */
  missing: boolean;
  /** The task ran more often than a minute; saving raises it. */
  readonly legacyInterval: boolean;
}

interface Picker {
  readonly title: string;
  /** A filter the user can type (the base branch picker). */
  readonly filter: { readonly query: string; readonly set: (query: string) => void } | null;
  readonly loading: boolean;
  readonly options: ReadonlyArray<{ readonly label: string; readonly run: () => void }>;
}

const WORKSPACE_LABEL: Record<WorkspaceMode, string> = {
  worktree: "A new worktree",
  root: "The project checkout",
  existing_worktree: "A specific checkout",
};
const WORKSPACE_ORDER: WorkspaceMode[] = ["worktree", "root", "existing_worktree"];
const RUNTIME_ORDER = Object.keys(RUNTIME_MODE_META) as RuntimeMode[];

export function scheduledTasksSection(host: SectionHost): SettingsSection {
  const { client } = host;
  let machines: Machine[] = [];
  /** The machine whose tasks are listed; null until the machines are read (this one). */
  let machineId: string | null = null;
  const listings = new Map<string, Listing>();
  let projectScope: string | null = null;
  let editor: Editor | null = null;
  let picker: Picker | null = null;
  let models: ModelOption[] = [];
  /** A task to open once the list has loaded (a link to it), and whether it was gone. */
  let linkedTaskId: string | null = null;
  let linkMissing = false;
  let editorSeq = 0;
  let generation = 0;
  let unsubscribe: (() => void) | null = null;
  /** Branch reads, so a slow one for an earlier filter does not replace a later one. */
  let branchGeneration = 0;

  const local = () => machines.find((machine) => machine.local) ?? null;
  const selected = () => machines.find((machine) => machine.id === machineId) ?? local() ?? null;
  const selectedId = () => selected()?.id ?? "local";
  /** The environment a call addresses: nothing for this machine. */
  const target = (id: string) =>
    machines.find((m) => m.id === id)?.local === false ? id : undefined;
  const projects = () => host.store.getState().shell?.projects ?? [];
  const projectTitle = (id: string) => projects().find((project) => project.id === id)?.title ?? id;

  const openLinked = () => {
    const listing = listings.get(selectedId());
    if (linkedTaskId === null || listing?.status !== "ready") return;
    const task = listing.tasks.find((candidate) => candidate.id === linkedTaskId);
    linkedTaskId = null;
    if (task) edit(task);
    else linkMissing = true;
  };

  const setTasks = (id: string, tasks: ReadonlyArray<ScheduledTask>) => {
    listings.set(id, { status: "ready", tasks });
    // An open editor learns that its task was deleted elsewhere.
    if (editor && editor.machineId === id && editor.draft.editingId !== null && !editor.saving) {
      editor.missing = !tasks.some((task) => task.id === editor!.draft.editingId);
    }
    openLinked();
    host.refresh();
  };

  const readTasks = (machine: Machine) => {
    if (!machine.online) {
      listings.set(machine.id, {
        status: "disconnected",
        message: `Reconnect ${machine.label} to view its scheduled tasks.`,
      });
      host.refresh();
      return;
    }
    const asked = generation;
    if (!listings.has(machine.id)) listings.set(machine.id, { status: "loading" });
    void host.track(
      client
        .mcCall<{ readonly tasks: ReadonlyArray<ScheduledTask> }>(
          "scheduledTasks.list",
          {},
          target(machine.id),
        )
        .then(
          (result) => {
            if (asked === generation) setTasks(machine.id, result.tasks ?? []);
          },
          (cause: unknown) => {
            if (asked !== generation) return;
            listings.set(machine.id, { status: "error", message: errorText(cause) });
            host.refresh();
          },
        ),
    );
  };

  const load = () => {
    const asked = ++generation;
    void host.track(
      Promise.all([readMachines(client), client.listModels().catch(() => [])]).then(
        ([nextMachines, nextModels]) => {
          if (asked !== generation) return;
          machines = nextMachines;
          models = nextModels;
          const here = local();
          if (here && unsubscribe === null) {
            unsubscribe = client.subscribeScheduledTasks((tasks) => {
              if (asked === generation) setTasks(here.id, tasks);
            });
          }
          const machine = selected();
          if (machine) readTasks(machine);
          host.refresh();
        },
      ),
    );
  };

  const defaultModel = (projectId: string): ModelSelection | null => {
    const project = projects().find((candidate) => candidate.id === projectId);
    const configured = (project as { defaultModelSelection?: ModelSelection | null } | undefined)
      ?.defaultModelSelection;
    if (configured) return configured;
    const first = models[0];
    return first ? ({ instanceId: first.instanceId, model: first.model } as ModelSelection) : null;
  };

  const openEditor = (draft: TaskDraft, legacyInterval: boolean) => {
    editor = {
      seq: ++editorSeq,
      machineId: selectedId(),
      draft,
      saving: false,
      problem: null,
      missing: false,
      legacyInterval,
    };
    picker = null;
    linkMissing = false;
    host.refresh();
    host.select("field-title");
  };

  const edit = (task: ScheduledTask) =>
    openEditor(
      taskToDraft(task),
      task.schedule.type === "interval" && task.schedule.everyMs < MIN_SCHEDULED_TASK_INTERVAL_MS,
    );

  const create = () => {
    const detail = host.store.getState().detail;
    const projectId = String(projectScope ?? detail?.projectId ?? projects()[0]?.id ?? "");
    openEditor(newTaskDraft({ projectId, modelSelection: defaultModel(projectId) }), false);
  };

  const change = (patch: Partial<TaskDraft>) => {
    if (!editor) return;
    editor.draft = { ...editor.draft, ...patch };
    editor.problem = null;
    host.refresh();
  };

  const fail = (target: Editor, problem: DraftProblem) => {
    target.saving = false;
    if (editor === target) {
      target.problem = problem;
      host.refresh();
    }
    // The page says how to fix it; the status row names the problem.
    host.status(problem.title, "error");
  };

  const upsertLocally = (id: string, task: ScheduledTask) => {
    const listing = listings.get(id);
    const tasks = listing?.status === "ready" ? listing.tasks : [];
    setTasks(
      id,
      tasks.some((known) => known.id === task.id)
        ? tasks.map((known) => (known.id === task.id ? task : known))
        : [...tasks, task],
    );
  };

  const send = (saving: Editor) => {
    const built = draftToUpsert(saving.draft);
    if ("problem" in built) {
      fail(saving, built.problem);
      return;
    }
    return client
      .mcCall<{ readonly task: ScheduledTask }>(
        "scheduledTasks.upsert",
        built.input,
        target(saving.machineId),
      )
      .then(
        (result) => {
          saving.saving = false;
          // A task the user opened while this save was on its way stays open.
          if (editor === saving) editor = null;
          upsertLocally(saving.machineId, result.task);
          host.status("Scheduled task saved.", "success");
          host.refresh();
        },
        (cause: unknown) =>
          fail(saving, { title: "Could not save scheduled task", detail: errorText(cause) }),
      );
  };

  const save = () => {
    const saving = editor;
    if (!saving || saving.saving) return;
    saving.problem = null;
    saving.saving = true;
    host.refresh();
    const machine = machines.find((candidate) => candidate.id === saving.machineId);
    if (!machine || machine.local) {
      void host.track(Promise.resolve(send(saving)));
      return;
    }
    // Another machine may have dropped off since the editor opened: ask again.
    void host.track(
      readMachines(client).then((next) => {
        machines = next;
        if (next.find((candidate) => candidate.id === saving.machineId)?.online !== true) {
          fail(saving, {
            title: "Reconnect this environment before saving",
            detail: "The task was not saved.",
          });
          return;
        }
        return send(saving);
      }),
    );
  };

  const mutate = (
    method: string,
    payload: Record<string, unknown>,
    machine: string,
    done: (result: { readonly task?: ScheduledTask }) => void,
    failure: string,
  ) => {
    void host.track(
      client
        .mcCall<{ readonly task?: ScheduledTask }>(method, payload, target(machine))
        .then(done, (cause: unknown) => host.status(`${failure}: ${errorText(cause)}`, "error")),
    );
  };

  const remove = (id: string, machine: string) =>
    mutate(
      "scheduledTasks.delete",
      { id },
      machine,
      () => {
        if (editor?.draft.editingId === id) editor = null;
        const listing = listings.get(machine);
        if (listing?.status === "ready") {
          setTasks(
            machine,
            listing.tasks.filter((task) => task.id !== id),
          );
        }
        host.status("Scheduled task deleted.", "success");
        host.refresh();
      },
      "Could not delete scheduled task",
    );

  const setEnabled = (id: string, machine: string, enabled: boolean) =>
    mutate(
      "scheduledTasks.setEnabled",
      { id, enabled },
      machine,
      (result) => {
        if (result.task) upsertLocally(machine, result.task);
        if (editor?.draft.editingId === id) change({ enabled });
        host.status(enabled ? "Scheduled task resumed." : "Scheduled task paused.", "success");
      },
      "Could not update scheduled task",
    );

  const runNow = (id: string, machine: string) =>
    mutate(
      "scheduledTasks.runNow",
      { id },
      machine,
      (result) => {
        if (result.task) upsertLocally(machine, result.task);
        host.status("Scheduled task started.", "success");
      },
      "Could not run scheduled task",
    );

  const pick = (next: Picker) => {
    picker = next;
    host.refresh();
  };
  const picked = () => {
    picker = null;
    host.refresh();
  };

  /** The base branch picker: the project's branches, narrowed by what the user types. */
  const pickBranch = (query: string) => {
    if (!editor) return;
    const cwd = projects().find((project) => project.id === editor!.draft.projectId)?.workspaceRoot;
    const asked = ++branchGeneration;
    const show = (names: ReadonlyArray<string>, loading: boolean) =>
      pick({
        title: "Base branch",
        filter: { query, set: pickBranch },
        loading,
        options: names.map((name) => ({
          label: name,
          run: () => {
            change({ baseRef: name });
            picked();
            host.select("field-baseRef");
          },
        })),
      });
    show([], true);
    if (!cwd) {
      show([], false);
      return;
    }
    void host.track(
      client.listRefs(cwd).then(
        (result) => {
          if (asked !== branchGeneration || picker?.title !== "Base branch") return;
          const needle = query.toLowerCase();
          show(
            result.refs
              .map((ref) => ref.name)
              .filter((name) => name.toLowerCase().includes(needle)),
            false,
          );
        },
        () => {
          if (asked === branchGeneration && picker?.title === "Base branch") show([], false);
        },
      ),
    );
  };

  const text = (
    id: string,
    label: string,
    value: string,
    field: keyof TaskDraft,
    placeholder = "",
  ): SectionItem => ({
    kind: "row",
    id: `field-${id}`,
    label,
    value: value === "" ? "—" : value,
    run: () => host.ask({ label, value, placeholder }, (next) => change({ [field]: next })),
  });

  const editorPage = (open: Editor): SectionItem[] => {
    const draft = open.draft;
    const here = machines.find((machine) => machine.id === open.machineId)?.local !== false;
    const items: SectionItem[] = [];
    if (open.missing) {
      items.push({
        kind: "note",
        text: "This task no longer exists. It was deleted from another client.",
        tone: "error",
      });
    }
    if (open.legacyInterval) {
      items.push({
        kind: "note",
        text: "This task runs more often than once a minute. Saving raises its interval to one minute.",
        tone: "warning",
      });
    }
    if (open.problem) {
      items.push({ kind: "note", text: open.problem.title, tone: "error" });
      items.push({ kind: "note", text: open.problem.detail });
    }
    items.push(text("title", "Title", draft.title, "title", "Check Sentry"));
    items.push(text("prompt", "Prompt", draft.prompt, "prompt", "What the agent should do"));
    items.push({
      kind: "row",
      id: "field-project",
      label: "Project",
      value: projectTitle(draft.projectId) || "—",
      // Another machine's projects are not listed here; its task keeps its project.
      ...(here
        ? {
            run: () =>
              pick({
                title: "Project",
                filter: null,
                loading: false,
                options: projects().map((project) => ({
                  label: project.title,
                  run: () => {
                    change({
                      projectId: project.id,
                      ...(draft.editingId === null
                        ? { modelSelection: defaultModel(project.id) }
                        : {}),
                    });
                    picked();
                    host.select("field-project");
                  },
                })),
              }),
          }
        : {}),
    });
    const model = draft.modelSelection;
    const modelOption = models.find(
      (option) => option.instanceId === model?.instanceId && option.model === model?.model,
    );
    items.push({
      kind: "row",
      id: "field-model",
      label: "Model",
      value: model
        ? modelOption
          ? `${modelOption.providerLabel} · ${modelOption.label}`
          : `${model.instanceId} · ${model.model}`
        : "—",
      ...(here
        ? {
            run: () =>
              pick({
                title: "Model",
                filter: null,
                loading: false,
                options: models.map((option) => ({
                  label: `${option.providerLabel} · ${option.label}`,
                  run: () => {
                    // Keep the options (reasoning, …) when the model itself is unchanged.
                    const same =
                      model?.instanceId === option.instanceId && model.model === option.model;
                    if (!same) {
                      change({
                        modelSelection: {
                          instanceId: option.instanceId,
                          model: option.model,
                        } as ModelSelection,
                      });
                    }
                    picked();
                    host.select("field-model");
                  },
                })),
              }),
          }
        : {}),
    });
    items.push({ kind: "blank" });
    items.push({
      kind: "row",
      id: "field-scheduleMode",
      label: "Schedule",
      value: draft.scheduleMode === "fixed" ? "At a time of day" : "Every few minutes",
      run: () => change({ scheduleMode: draft.scheduleMode === "fixed" ? "interval" : "fixed" }),
    });
    if (draft.scheduleMode === "fixed") {
      items.push(text("timeOfDay", "Time", draft.timeOfDay, "timeOfDay", "09:00"));
      for (const day of DAY_ORDER) {
        items.push({
          kind: "row",
          id: `field-day-${day}`,
          label: `  ${DAY_NAMES[day]}`,
          value: draft.weekdays.includes(day) ? "on" : "off",
          tone: draft.weekdays.includes(day) ? "success" : "dim",
          run: () => change({ weekdays: toggleDay(draft.weekdays, day) }),
        });
      }
    } else {
      items.push(
        text("intervalMinutes", "Every (minutes)", draft.intervalMinutes, "intervalMinutes", "15"),
      );
    }
    items.push({ kind: "blank" });
    items.push({
      kind: "row",
      id: "field-workspaceMode",
      label: "Runs in",
      value: WORKSPACE_LABEL[draft.workspaceMode],
      run: () =>
        change({
          workspaceMode:
            WORKSPACE_ORDER[
              (WORKSPACE_ORDER.indexOf(draft.workspaceMode) + 1) % WORKSPACE_ORDER.length
            ]!,
        }),
    });
    if (draft.workspaceMode === "worktree") {
      items.push({
        kind: "row",
        id: "field-baseRef",
        label: "Base branch",
        value: draft.baseRef,
        run: () => pickBranch(""),
      });
      items.push({
        kind: "row",
        id: "field-startFromOrigin",
        label: "Fetch from origin",
        value: draft.startFromOrigin ? "yes" : "no",
        run: () => change({ startFromOrigin: !draft.startFromOrigin }),
      });
    } else if (draft.workspaceMode === "existing_worktree") {
      items.push(
        text(
          "checkoutPath",
          "Checkout path",
          draft.checkoutPath,
          "checkoutPath",
          "/path/to/checkout",
        ),
      );
    }
    items.push({
      kind: "row",
      id: "field-runtimeMode",
      label: "Access",
      value: RUNTIME_MODE_META[draft.runtimeMode]?.label ?? draft.runtimeMode,
      run: () =>
        change({
          runtimeMode:
            RUNTIME_ORDER[(RUNTIME_ORDER.indexOf(draft.runtimeMode) + 1) % RUNTIME_ORDER.length]!,
        }),
    });
    items.push({ kind: "blank" });
    items.push({
      kind: "row",
      id: "save",
      label: open.saving ? "Saving…" : "Save task",
      tone: "accent",
      run: save,
    });
    const id = draft.editingId;
    if (id !== null && !open.missing) {
      items.push({
        kind: "row",
        id: "toggle",
        label: draft.enabled ? "Pause task" : "Resume task",
        run: () => setEnabled(id, open.machineId, !draft.enabled),
      });
      items.push({
        kind: "row",
        id: "run",
        label: "Run now",
        run: () => runNow(id, open.machineId),
      });
      items.push({
        kind: "row",
        id: "delete",
        label: "Delete task",
        tone: "error",
        run: () =>
          host.confirm(`Delete the scheduled task "${draft.title}"? It stops running.`, () =>
            remove(id, open.machineId),
          ),
      });
    }
    return items;
  };

  const pickerPage = (open: Picker): SectionItem[] => {
    const items: SectionItem[] = [];
    if (open.filter) {
      const filter = open.filter;
      items.push({
        kind: "row",
        id: "picker-filter",
        label: "Filter",
        value: filter.query === "" ? "type to narrow the list" : filter.query,
        run: () =>
          host.ask(
            { label: "Filter", value: filter.query, placeholder: "branch name" },
            filter.set,
          ),
      });
    }
    if (open.loading) items.push({ kind: "note", text: "Loading…" });
    else if (open.options.length === 0) items.push({ kind: "note", text: "Nothing matches." });
    open.options.forEach((option, index) => {
      items.push({ kind: "row", id: `picker-${index}`, label: option.label, run: option.run });
    });
    return items;
  };

  const listPage = (): SectionItem[] => {
    const items: SectionItem[] = [];
    const machine = selected();
    if (machines.length > 1 && machine) {
      items.push({
        kind: "row",
        id: "machine",
        label: "Machine",
        value: machine.label,
        run: () => {
          const next = machines[(machines.indexOf(machine) + 1) % machines.length]!;
          machineId = next.id;
          linkMissing = false;
          readTasks(next);
          host.refresh();
        },
      });
    }
    const scoped = projects().find((project) => project.id === projectScope);
    items.push({
      kind: "row",
      id: "project",
      label: "Project",
      value: scoped ? scoped.title : "All projects",
      run: () => {
        const ids: Array<string | null> = [
          null,
          ...projects().map((project) => String(project.id)),
        ];
        projectScope = ids[(ids.indexOf(projectScope) + 1) % ids.length] ?? null;
        host.refresh();
      },
    });
    const listing: Listing = listings.get(selectedId()) ?? { status: "loading" };
    if (listing.status === "disconnected") {
      items.push({ kind: "blank" });
      items.push({ kind: "note", text: listing.message, tone: "warning" });
      items.push({ kind: "row", id: "retry", label: "Try again", run: load });
      return items;
    }
    if (machine?.local !== false) {
      items.push({ kind: "row", id: "new", label: "+ New task", tone: "accent", run: create });
    }
    items.push({ kind: "blank" });
    if (linkMissing) {
      items.push({
        kind: "note",
        text: "That scheduled task is unavailable. It may have been deleted.",
        tone: "error",
      });
    }
    if (listing.status === "loading") {
      items.push({ kind: "note", text: "Loading scheduled tasks…" });
      return items;
    }
    if (listing.status === "error") {
      items.push({ kind: "note", text: listing.message, tone: "error" });
      return items;
    }
    const tasks = listing.tasks.filter(
      (task) => projectScope === null || task.projectId === projectScope,
    );
    if (tasks.length === 0) {
      items.push({ kind: "note", text: "No scheduled tasks yet." });
    }
    const now = host.now();
    for (const task of tasks) {
      items.push({
        kind: "row",
        id: `task-${task.id}`,
        label: task.title,
        value: `${whenLabel(task, now)} · ${scheduleLabel(task.schedule)} · ${lastRunLabel(task)}`,
        tone: task.lastRunStatus === "failed" ? "error" : task.enabled ? "text" : "dim",
        run: () => edit(task),
      });
      items.push({
        kind: "note",
        indent: 2,
        text: `${projectTitle(task.projectId)} · ${task.prompt}`,
      });
      if (task.lastRunStatus === "failed" && task.lastRunError) {
        items.push({
          kind: "note",
          indent: 2,
          text: `Last error: ${task.lastRunError}`,
          tone: "error",
        });
      }
    }
    return items;
  };

  const field = (payload: unknown, name: string): unknown =>
    typeof payload === "object" && payload !== null
      ? (payload as Record<string, unknown>)[name]
      : undefined;

  return {
    id: "scheduledTasks",
    commands: () => [
      {
        id: "section.scheduledTasks",
        title: "Scheduled tasks",
        keywords: "schedule timer cron recurring automation settings",
        action: "section.open",
        payload: { id: "scheduledTasks" },
      },
    ],
    open: (payload) => {
      unsubscribe?.();
      unsubscribe = null;
      listings.clear();
      editor = null;
      picker = null;
      linkMissing = false;
      const environmentId = field(payload, "environmentId");
      const taskId = field(payload, "taskId");
      const projectId = field(payload, "projectId");
      machineId = typeof environmentId === "string" ? environmentId : null;
      linkedTaskId = typeof taskId === "string" ? taskId : null;
      projectScope = typeof projectId === "string" ? projectId : null;
      load();
    },
    close: () => {
      generation += 1;
      unsubscribe?.();
      unsubscribe = null;
      editor = null;
      picker = null;
    },
    back: () => {
      if (picker) {
        picker = null;
        return true;
      }
      if (editor) {
        editor = null;
        return true;
      }
      return false;
    },
    page: () => {
      if (picker) return { title: `scheduled tasks · ${picker.title}`, items: pickerPage(picker) };
      if (editor) {
        return {
          title: `scheduled tasks · ${editor.draft.editingId === null ? "new task" : editor.draft.title}`,
          items: editorPage(editor),
        };
      }
      return { title: "scheduled tasks", items: listPage() };
    },
  };
}
