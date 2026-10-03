// Steps for settings/scheduled-tasks.feature (@shared): the scheduled tasks
// page and its editor, against a fake MC that keeps each machine's tasks as
// HalC2.ScheduledTasks does and answers `scheduledTasks.*`.
import { expect } from "bun:test";
import type { ScheduledTask } from "@hal-c2/contracts";

import { step } from "../../steps.ts";
import { toggleDay } from "../../../src/host/sections/scheduledTasks.ts";
import { runPaletteCommand } from "./controls.steps.ts";
import {
  chooseRow,
  connected,
  fillField,
  fixture,
  linkMachine,
  mc,
  openSection,
  pageText,
  paneWords,
  sectionState,
  selectRow,
  type SettingsWorld,
} from "../settingsWorld.ts";
import { pressKey, settle } from "../world.ts";

interface FakeTasks {
  /** Tasks by environment; "" is the MC the terminal is connected to. */
  readonly byMachine: Map<string, ScheduledTask[]>;
  next: number;
  /** Saves held back until released (a slow MC); null answers at once. */
  held: Array<() => void> | null;
}

interface TasksWorld extends SettingsWorld {
  fakeTasks?: FakeTasks;
}

const words = (text: string) => text.replace(/\s+/g, " ");

function fakeTasks(ctx: TasksWorld): FakeTasks {
  if (ctx.fakeTasks) return ctx.fakeTasks;
  const fake: FakeTasks = { byMachine: new Map(), next: 0, held: null };
  ctx.fakeTasks = fake;
  const server = mc(ctx);
  const tasksOf = (environmentId: string | undefined) => {
    const key = environmentId ?? "";
    if (!fake.byMachine.has(key)) fake.byMachine.set(key, []);
    return fake.byMachine.get(key)!;
  };
  // The MC tells its watchers after every change to its own tasks.
  const broadcast = () => server.emitScheduledTasks([...tasksOf(undefined)]);
  server.onScheduledTasksSubscribe = broadcast;
  server.on("scheduledTasks.list", (_payload, environmentId) => ({
    tasks: [...tasksOf(environmentId)],
  }));
  const upsert = (payload: Record<string, unknown>, environmentId: string | undefined) => {
    const tasks = tasksOf(environmentId);
    const at = tasks.findIndex((task) => task.id === payload.id);
    if (at < 0 && payload.requireExisting === true) throw new Error("Schedule task not found.");
    const { requireExisting: _requireExisting, ...fields } = payload;
    const task = {
      lastRunStatus: "never",
      lastRunError: null,
      ...(at < 0 ? {} : tasks[at]),
      ...fields,
      id: payload.id ?? `task-${++fake.next}`,
      nextRunAt: payload.enabled ? "2099-01-01T09:00:00.000Z" : null,
    } as unknown as ScheduledTask;
    if (at < 0) tasks.push(task);
    else tasks[at] = task;
    if (environmentId === undefined) broadcast();
    return { task };
  };
  server.on("scheduledTasks.upsert", (payload, environmentId) => {
    if (fake.held === null) return upsert(payload, environmentId);
    return new Promise((resolve, reject) => {
      fake.held!.push(() => {
        try {
          resolve(upsert(payload, environmentId));
        } catch (error) {
          reject(error);
        }
      });
    });
  });
  server.on("scheduledTasks.delete", (payload, environmentId) => {
    const tasks = tasksOf(environmentId);
    const at = tasks.findIndex((task) => task.id === payload.id);
    if (at < 0) throw new Error("Schedule task not found.");
    tasks.splice(at, 1);
    if (environmentId === undefined) broadcast();
    return { id: payload.id };
  });
  server.on("scheduledTasks.setEnabled", (payload, environmentId) => {
    const tasks = tasksOf(environmentId);
    const at = tasks.findIndex((task) => task.id === payload.id);
    if (at < 0) throw new Error("Schedule task not found.");
    tasks[at] = { ...tasks[at]!, enabled: payload.enabled };
    if (environmentId === undefined) broadcast();
    return { task: tasks[at] };
  });
  return fake;
}

const stored = (ctx: TasksWorld, environmentId = "") =>
  fakeTasks(ctx).byMachine.get(environmentId) ?? [];

function task(
  id: string,
  title: string,
  projectId: string,
  fields: Record<string, unknown> = {},
): ScheduledTask {
  return {
    id,
    title,
    prompt: `Look at ${title}`,
    enabled: true,
    schedule: { type: "fixed_time", timeOfDay: "09:00" },
    projectId,
    threadId: null,
    workspaceStrategy: { type: "root" },
    modelSelection: { instanceId: "codex", model: "codex-model" },
    runtimeMode: "full-access",
    interactionMode: "default",
    nextRunAt: "2099-01-01T09:00:00.000Z",
    lastRunStatus: "succeeded",
    lastRunError: null,
    ...fields,
  } as unknown as ScheduledTask;
}

const seed = (ctx: TasksWorld, seeded: ScheduledTask, environmentId = "") => {
  const fake = fakeTasks(ctx);
  fake.byMachine.set(environmentId, [...stored(ctx, environmentId), seeded]);
};

/** Open the page as its palette entry does. */
async function openTasks(ctx: TasksWorld): Promise<void> {
  fakeTasks(ctx);
  await connected(ctx);
  if (sectionState(ctx).id === "scheduledTasks") return;
  await runPaletteCommand(ctx, "Scheduled tasks");
  expect(sectionState(ctx).id).toBe("scheduledTasks");
}

/** Set one of the editor's text fields through its one-line field. */
async function setField(ctx: TasksWorld, label: string, value: string): Promise<void> {
  await chooseRow(ctx, label);
  await fillField(ctx, value);
}

/** A new task's editor with a title and a prompt typed in. */
async function newTask(ctx: TasksWorld, fill = true): Promise<void> {
  await openTasks(ctx);
  await chooseRow(ctx, "+ New task");
  expect(sectionState(ctx).title).toBe("scheduled tasks · new task");
  if (!fill) return;
  await setField(ctx, "Title", "Check Sentry");
  await setField(ctx, "Prompt", "Look at the new Sentry issues.");
}

const save = (ctx: TasksWorld) => chooseRow(ctx, "Save task");

/** The one task the scenario saved, once the editor closed on it. */
function savedTask(ctx: TasksWorld): ScheduledTask {
  expect(sectionState(ctx).title).toBe("scheduled tasks");
  expect(stored(ctx)).toHaveLength(1);
  return stored(ctx)[0]!;
}

step("the user starts a new task", async (ctx: TasksWorld) => {
  await newTask(ctx, false);
});

step(
  "it starts in a new worktree from {string} fetched from origin",
  async (ctx: TasksWorld, base: string) => {
    const page = words(pageText(ctx));
    expect(page).toContain("Runs in A new worktree");
    expect(page).toContain(`Base branch ${base}`);
    expect(page).toContain("Fetch from origin yes");
    expect(await paneWords(ctx)).toContain(`Base branch ${base}`);
  },
);

step("it runs at 09:00 on weekdays with full access", async (ctx: TasksWorld) => {
  const page = words(pageText(ctx));
  expect(page).toContain("Schedule At a time of day");
  expect(page).toContain("Time 09:00");
  expect(page).toContain("Friday on");
  expect(page).toContain("Saturday off");
  expect(page).toContain("Access Full access");
  // And that is what the MC is asked to keep.
  await setField(ctx, "Title", "Check Sentry");
  await setField(ctx, "Prompt", "Look at the new Sentry issues.");
  await save(ctx);
  const saved = savedTask(ctx);
  expect(saved.schedule).toEqual({
    type: "fixed_time",
    timeOfDay: "09:00",
    weekdays: [1, 2, 3, 4, 5],
  });
  expect(saved.runtimeMode).toBe("full-access");
  expect(saved.workspaceStrategy).toEqual({
    type: "worktree",
    baseRef: "main",
    startFromOrigin: true,
  });
});

step("its model is the project's default model", (ctx: TasksWorld) => {
  // "api" defaults to Claude's model, which is not the first one listed.
  expect(savedTask(ctx).modelSelection).toEqual({ instanceId: "claude", model: "claude-model" });
});

const WORKSPACE_ROW = {
  "a new worktree": "A new worktree",
  "the project checkout": "The project checkout",
  "a specific checkout": "A specific checkout",
} as const;

/** Press Enter on "Runs in" until it reads `label`. */
async function chooseWorkspace(ctx: TasksWorld, label: string): Promise<void> {
  for (let turn = 0; turn < 3 && !words(pageText(ctx)).includes(`Runs in ${label}`); turn += 1) {
    await chooseRow(ctx, "Runs in");
  }
  expect(words(pageText(ctx))).toContain(`Runs in ${label}`);
}

step(
  /^the user creates a task that uses (a new worktree|the project checkout|a specific checkout)$/,
  async (ctx: TasksWorld, workspace: keyof typeof WORKSPACE_ROW) => {
    await newTask(ctx);
    await chooseWorkspace(ctx, WORKSPACE_ROW[workspace]);
    if (workspace === "a specific checkout")
      await setField(ctx, "Checkout path", "/work/api-review");
    await save(ctx);
  },
);

step(
  /^each run works in (a fresh worktree from the base|the project root|the chosen checkout path)$/,
  (ctx: TasksWorld, place: string) => {
    expect(savedTask(ctx).workspaceStrategy).toEqual(
      place === "the project root"
        ? { type: "root" }
        : place === "the chosen checkout path"
          ? { type: "existing_worktree", worktreePath: "/work/api-review" }
          : { type: "worktree", baseRef: "main", startFromOrigin: true },
    );
  },
);

step(
  /^the user saves a task (without a prompt|that runs every 0 minutes|that uses a specific checkout with no path)$/,
  async (ctx: TasksWorld, problem: string) => {
    await newTask(ctx, false);
    await setField(ctx, "Title", "Check Sentry");
    if (problem !== "without a prompt")
      await setField(ctx, "Prompt", "Look at the new Sentry issues.");
    if (problem === "that runs every 0 minutes") {
      await chooseRow(ctx, "Schedule");
      await setField(ctx, "Every (minutes)", "0");
    }
    if (problem === "that uses a specific checkout with no path") {
      await chooseWorkspace(ctx, "A specific checkout");
    }
    await save(ctx);
    // The page says what to fix (the status row names the problem).
    expect(await paneWords(ctx)).toContain(
      problem === "without a prompt"
        ? "Scheduled task is incomplete Add a title, prompt, project, and model."
        : problem === "that runs every 0 minutes"
          ? "Invalid interval Enter an interval of at least one minute."
          : "Checkout path is required Enter the path of the checkout to run in.",
    );
    // Nothing reached the MC, and the editor stays open on the task.
    expect(mc(ctx).callsTo("scheduledTasks.upsert")).toEqual([]);
    expect(stored(ctx)).toEqual([]);
    expect(sectionState(ctx).title).toBe("scheduled tasks · new task");
  },
);

step("the user saves a task on an environment that is disconnected", async (ctx: TasksWorld) => {
  // The task's editor is open on another machine when its link drops.
  const laptop = linkMachine(ctx, "Laptop");
  seed(ctx, task("task-sentry", "Check Sentry", "api"), laptop.id);
  await openTasks(ctx);
  await chooseRow(ctx, "Machine");
  expect(words(pageText(ctx))).toContain("Machine Laptop");
  await chooseRow(ctx, "Check Sentry");
  expect(sectionState(ctx).title).toBe("scheduled tasks · Check Sentry");
  laptop.online = false;
  await save(ctx);
  expect(mc(ctx).callsTo("scheduledTasks.upsert")).toEqual([]);
  expect(await paneWords(ctx)).toContain(
    "Reconnect this environment before saving The task was not saved.",
  );
  expect(sectionState(ctx).title).toBe("scheduled tasks · Check Sentry");
});

step("a paused task and a task that failed its last run", (ctx: TasksWorld) => {
  seed(ctx, task("paused", "Nightly build", "api", { enabled: false, nextRunAt: null }));
  seed(
    ctx,
    task("failed", "Check Sentry", "api", {
      lastRunStatus: "failed",
      lastRunError: "The server stopped during this run.",
    }),
  );
});

step("the user opens scheduled tasks", openTasks);

/** The list's lines for one task: its row and the notes under it. */
function taskLines(ctx: TasksWorld, title: string): string[] {
  const lines = sectionState(ctx).lines;
  const from = lines.findIndex((line) => line.trim().startsWith(title));
  expect(from, `no "${title}" in the list:\n${pageText(ctx)}`).toBeGreaterThanOrEqual(0);
  const rest = lines.slice(from + 1);
  const next = rest.findIndex((line) => /^ {2}\S/.test(line));
  return [lines[from]!, ...rest.slice(0, next < 0 ? rest.length : next)];
}

step("the paused task says it is paused", async (ctx: TasksWorld) => {
  expect(words(taskLines(ctx, "Nightly build").join(" "))).toContain("Nightly build Paused");
  expect(words(taskLines(ctx, "Check Sentry").join(" "))).toContain("Check Sentry Next run in");
  expect(await paneWords(ctx)).toContain("Nightly build Paused");
});

step("the failed task shows its last error", async (ctx: TasksWorld) => {
  expect(words(taskLines(ctx, "Check Sentry").join(" "))).toContain(
    "Last error: The server stopped during this run.",
  );
  expect(words(taskLines(ctx, "Nightly build").join(" "))).not.toContain("Last error");
  expect(await paneWords(ctx)).toContain("Last error: The server stopped during this run.");
});

step("the failed task is badged {string}", (ctx: TasksWorld, badge: string) => {
  expect(words(taskLines(ctx, "Check Sentry").join(" "))).toContain(`· ${badge}`);
  expect(words(taskLines(ctx, "Nightly build").join(" "))).not.toContain(badge);
});

step("each task shows its prompt", async (ctx: TasksWorld) => {
  const screen = await paneWords(ctx);
  for (const title of ["Nightly build", "Check Sentry"]) {
    expect(words(taskLines(ctx, title).join(" "))).toContain(`Look at ${title}`);
    expect(screen).toContain(`Look at ${title}`);
  }
});

step(
  "tasks in projects {string} and {string}",
  (ctx: TasksWorld, first: string, second: string) => {
    const projects = fixture(ctx).projects;
    for (const project of [first, second]) {
      if (!projects.includes(project)) projects.push(project);
      seed(ctx, task(`${project}-task`, `${project} review`, project));
    }
  },
);

step(
  "the user views scheduled tasks for project {string}",
  async (ctx: TasksWorld, project: string) => {
    await openTasks(ctx);
    expect(pageText(ctx)).toContain("api review");
    expect(pageText(ctx)).toContain("web review");
    // Enter on the scope row walks the projects.
    for (
      let turn = 0;
      turn < 4 && !words(pageText(ctx)).includes(`Project ${project}`);
      turn += 1
    ) {
      await chooseRow(ctx, "Project");
    }
    expect(words(pageText(ctx))).toContain(`Project ${project}`);
  },
);

step("only the tasks for {string} are listed", async (ctx: TasksWorld, project: string) => {
  const titles = sectionState(ctx).lines.filter((line) => /^ {2}\S+ review/.test(line));
  expect(titles).toHaveLength(1);
  expect(titles[0]).toContain(`${project} review`);
  const screen = await paneWords(ctx);
  expect(screen).toContain(`${project} review`);
  expect(screen).not.toContain(project === "api" ? "web review" : "api review");
});

step("a task {string}", (ctx: TasksWorld, title: string) => {
  seed(ctx, task("task-sentry", title, "api"));
});

step("the user deletes the task", async (ctx: TasksWorld) => {
  await openTasks(ctx);
  await chooseRow(ctx, "Check Sentry");
  await chooseRow(ctx, "Delete task");
  // Deleting asks first.
  expect(sectionState(ctx).confirm?.lines.join(" ")).toContain(
    'Delete the scheduled task "Check Sentry"?',
  );
  expect(stored(ctx)).toHaveLength(1);
  await pressKey(ctx, "y");
  await settle(ctx);
});

step("it no longer runs and is no longer listed", async (ctx: TasksWorld) => {
  expect(
    mc(ctx)
      .callsTo("scheduledTasks.delete")
      .map((call) => call.payload),
  ).toEqual([{ id: "task-sentry" }]);
  expect(stored(ctx)).toEqual([]);
  expect(sectionState(ctx).title).toBe("scheduled tasks");
  expect(pageText(ctx)).not.toContain("Check Sentry");
  expect(await paneWords(ctx)).toContain("No scheduled tasks yet.");
});

step("the user follows a link to a task that was deleted", async (ctx: TasksWorld) => {
  fakeTasks(ctx);
  await openSection(ctx, "scheduledTasks", { taskId: "task-gone" });
});

step("the user is told the task is unavailable", async (ctx: TasksWorld) => {
  const message = "That scheduled task is unavailable. It may have been deleted.";
  expect(words(pageText(ctx))).toContain(message);
  expect(await paneWords(ctx)).toContain(message);
  // No editor opened: the list is shown.
  expect(sectionState(ctx).title).toBe("scheduled tasks");
});

step("the environment {string} is disconnected", (ctx: TasksWorld, label: string) => {
  linkMachine(ctx, label, false);
});

step("the user opens scheduled tasks for {string}", async (ctx: TasksWorld, label: string) => {
  await openTasks(ctx);
  for (let turn = 0; turn < 3 && !words(pageText(ctx)).includes(`Machine ${label}`); turn += 1) {
    await chooseRow(ctx, "Machine");
  }
  expect(words(pageText(ctx))).toContain(`Machine ${label}`);
});

step("the user is offered to reconnect {string}", async (ctx: TasksWorld, label: string) => {
  const message = `Reconnect ${label} to view its scheduled tasks.`;
  expect(words(pageText(ctx))).toContain(message);
  expect(await paneWords(ctx)).toContain(message);
  // Its tasks were not asked for, and trying again reads the machines anew.
  expect(
    mc(ctx)
      .callsTo("scheduledTasks.list")
      .filter((call) => call.environmentId),
  ).toEqual([]);
  expect(pageText(ctx)).not.toContain("+ New task");
  linkMachine(ctx, label, true);
  await chooseRow(ctx, "Try again");
  expect(pageText(ctx)).not.toContain(message);
  expect(mc(ctx).callsTo("scheduledTasks.list").at(-1)?.environmentId).toBe(`env-${label}`);
});

step(
  "the user saves a task and starts another before the save is answered",
  async (ctx: TasksWorld) => {
    const fake = fakeTasks(ctx);
    await newTask(ctx);
    fake.held = [];
    ctx.held = 1;
    await save(ctx);
    expect(pageText(ctx)).toContain("Saving…");
    expect(fake.held).toHaveLength(1);
    // Back to the list and into a new task while the MC has not answered.
    await pressKey(ctx, "Esc");
    await settle(ctx);
    await chooseRow(ctx, "+ New task");
    await setField(ctx, "Title", "Second task");
    expect(sectionState(ctx).title).toBe("scheduled tasks · new task");
    for (const release of fake.held.splice(0)) release();
    fake.held = null;
    ctx.held = 0;
    await settle(ctx);
  },
);

step("the first task is saved and the new task stays open", async (ctx: TasksWorld) => {
  expect(stored(ctx).map((saved) => saved.title)).toEqual(["Check Sentry"]);
  // The second task's editor is still open, with what was typed and not saving.
  expect(sectionState(ctx).title).toBe("scheduled tasks · new task");
  expect(words(pageText(ctx))).toContain("Title Second task");
  expect(pageText(ctx)).toContain("Save task");
  expect(await paneWords(ctx)).toContain("Title Second task");
  // And the list behind it has the first.
  await pressKey(ctx, "Esc");
  await settle(ctx);
  expect(pageText(ctx)).toContain("Check Sentry");
});

step(
  "the project {string} has the branches {string}",
  (ctx: TasksWorld, _project: string, branches: string) => {
    const names = branches.split(",").map((name) => name.trim());
    mc(ctx);
    ctx.fake!.override("listRefs", (async () => ({
      refs: names.map((name, index) => ({
        name,
        current: index === 0,
        isDefault: index === 0,
        worktreePath: null,
      })),
      isRepo: true,
      hasPrimaryRemote: true,
      nextCursor: null,
      totalCount: names.length,
    })) as never);
  },
);

step(
  "the user starts a new task and types {string} as its base branch",
  async (ctx: TasksWorld, typed: string) => {
    await newTask(ctx, false);
    await chooseRow(ctx, "Base branch");
    expect(sectionState(ctx).title).toBe("scheduled tasks · Base branch");
    // Every branch is offered until the user narrows them.
    expect(pageText(ctx)).toContain("feature/login");
    await chooseRow(ctx, "Filter");
    await fillField(ctx, typed);
  },
);

step("the base branches offered are {string}", async (ctx: TasksWorld, offered: string) => {
  const wanted = offered.split(",").map((name) => name.trim());
  const rows = sectionState(ctx)
    .lines.map((line) => line.trim())
    .filter((line) => line !== "" && !line.startsWith("Filter"));
  expect(rows).toEqual(wanted);
  const screen = await paneWords(ctx);
  expect(screen).toContain(wanted[0]!);
  expect(screen).not.toContain("feature/login");
  // Choosing one sets it as the base.
  await chooseRow(ctx, wanted[0]!);
  expect(words(pageText(ctx))).toContain(`Base branch ${wanted[0]}`);
});

step("a new task that runs only on Wednesday", async (ctx: TasksWorld) => {
  await newTask(ctx);
  // Weekdays are on by default: turn the others off.
  for (const day of ["Monday", "Tuesday", "Thursday", "Friday"]) await chooseRow(ctx, day);
  const page = words(pageText(ctx));
  expect(page).toContain("Wednesday on");
  for (const day of ["Monday", "Tuesday", "Thursday", "Friday", "Saturday", "Sunday"]) {
    expect(page).toContain(`${day} off`);
  }
});

step("the user turns Wednesday off and saves it", async (ctx: TasksWorld) => {
  await chooseRow(ctx, "Wednesday");
  // The row does not turn off: a fixed-time task runs on some day.
  expect(words(pageText(ctx))).toContain("Wednesday on");
  expect(toggleDay([3], 3)).toEqual([3]);
  await save(ctx);
});

step("the task still runs on Wednesday", (ctx: TasksWorld) => {
  expect(savedTask(ctx).schedule).toEqual({
    type: "fixed_time",
    timeOfDay: "09:00",
    weekdays: [3],
  });
});

step("a task saved by an older version that runs every 10 seconds", (ctx: TasksWorld) => {
  seed(
    ctx,
    task("task-legacy", "Poll", "api", { schedule: { type: "interval", everyMs: 10_000 } }),
  );
});

step("the user edits it", async (ctx: TasksWorld) => {
  await openTasks(ctx);
  expect(words(pageText(ctx))).toContain("Every 10 sec");
  await chooseRow(ctx, "Poll");
  expect(sectionState(ctx).title).toBe("scheduled tasks · Poll");
});

step("the editor says saving raises the interval to a minute", async (ctx: TasksWorld) => {
  const message =
    "This task runs more often than once a minute. Saving raises its interval to one minute.";
  expect(words(pageText(ctx))).toContain(message);
  expect(await paneWords(ctx)).toContain(message);
  expect(words(pageText(ctx))).toContain("Every (minutes) 1");
});

step("saving it runs every minute", async (ctx: TasksWorld) => {
  await save(ctx);
  expect(savedTask(ctx).schedule).toEqual({ type: "interval", everyMs: 60_000 });
  expect(words(pageText(ctx))).toContain("Every 1 min");
});

step("the user edits the task and another client deletes it", async (ctx: TasksWorld) => {
  await openTasks(ctx);
  await chooseRow(ctx, "Check Sentry");
  expect(sectionState(ctx).title).toBe("scheduled tasks · Check Sentry");
  expect(pageText(ctx)).not.toContain("no longer exists");
  // The MC tells its watchers the task is gone.
  fakeTasks(ctx).byMachine.set("", []);
  mc(ctx).emitScheduledTasks([]);
  await settle(ctx);
});

step("the editor says the task no longer exists", async (ctx: TasksWorld) => {
  const message = "This task no longer exists. It was deleted from another client.";
  expect(words(pageText(ctx))).toContain(message);
  expect(await paneWords(ctx)).toContain(message);
  // The editor stays open with what the user had, and saving is refused by the MC.
  expect(sectionState(ctx).title).toBe("scheduled tasks · Check Sentry");
  expect(pageText(ctx)).not.toContain("Delete task");
  await selectRow(ctx, "Save task");
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(words(pageText(ctx))).toContain("Schedule task not found.");
  expect(stored(ctx)).toEqual([]);
});
