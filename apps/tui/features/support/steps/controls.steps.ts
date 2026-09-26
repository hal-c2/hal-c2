// Composer controls and new-thread drafts (features/tui/composer-controls.feature,
// composer/model-and-mode.feature, providers/*): the footer, the pickers, the
// palette and what the fake client was asked.
import { expect } from "bun:test";

import {
  DEFAULT_SERVER_SETTINGS,
  type OrchestrationThread,
  type ServerProvider,
  type VcsRef,
} from "@t3tools/contracts";

import { step } from "../../steps.ts";
import { flattenModelOptions } from "../../../src/models.ts";
import type { TuiSelectState } from "../../../src/host/composerState.ts";
import type { TuiPaletteState } from "../../../src/host/paletteState.ts";
import { PROVIDERS, project, shell, thread } from "../fakeClient.ts";
import {
  clickObject,
  findObject,
  geometry,
  pressKey,
  resize,
  settle,
  snapshot,
  typeText,
  useClient,
  type World,
} from "../world.ts";
import {
  PNG,
  callsTo,
  composer,
  openOnThread,
  typeIntoPrompt,
  updateThread,
  type ComposerWorld,
} from "./composer.steps.ts";

export interface ControlsWorld extends ComposerWorld {
  /** Text typed into a draft before an outcome checks it survived. */
  draftText?: string;
  /** Answers a request a step left hanging. */
  release?: (outcome?: unknown) => void;
  /** The running client, to prove a later step did not restart it. */
  booted?: World["app"];
}

export const REFS = [
  { name: "main", current: true, isDefault: true, worktreePath: null },
  { name: "develop", current: false, isDefault: false, worktreePath: null },
  {
    name: "feature/x",
    current: false,
    isDefault: false,
    worktreePath: "/workspace/project-one-x",
  },
] as unknown as ReadonlyArray<VcsRef>;

const refsResult = (refs: ReadonlyArray<VcsRef>) =>
  ({
    refs,
    isRepo: true,
    hasPrimaryRemote: true,
    nextCursor: null,
    totalCount: refs.length,
  }) as never;

export const select = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;
const palette = (ctx: World) => ctx.host!.state.get("palette") as TuiPaletteState;
const status = (ctx: World) => (ctx.host!.state.get("status") as { text: string }).text;

/** Tear the running client down and open it again on a different fixture. */
export async function restartClient(
  ctx: ControlsWorld,
  options: Parameters<typeof useClient>[1] & { detail?: OrchestrationThread } = {},
): Promise<void> {
  for (const cleanup of ctx.cleanups.splice(0).reverse()) await cleanup();
  delete ctx.app;
  delete ctx.host;
  delete ctx.fake;
  ctx.dispatched = [];
  await openOnThread(ctx, options.detail ?? thread(), options);
}

/** Move the open picker's highlight to `label` with the arrow keys, then Enter. */
export async function chooseInPicker(ctx: World, label: string): Promise<void> {
  await settle(ctx);
  const current = select(ctx);
  expect(current.open).toBe(true);
  const target = current.options.findIndex((option) => option.label === label);
  expect(target).toBeGreaterThanOrEqual(0);
  while (select(ctx).index !== target) {
    await pressKey(ctx, select(ctx).index < target ? "Down" : "Up");
    await settle(ctx);
  }
  await pressKey(ctx, "Enter");
  await settle(ctx);
}

/** Run a palette command by typing its title. */
export async function runPaletteCommand(ctx: World, title: string): Promise<void> {
  await pressKey(ctx, "Ctrl+K");
  await typeText(ctx, title.toLowerCase());
  await settle(ctx);
  expect(palette(ctx).commands[palette(ctx).index]?.title).toBe(title);
  await pressKey(ctx, "Enter");
  await settle(ctx);
}

/** Replace the text of the open picker's field (it starts at "~/"). */
async function fillPickerInput(ctx: World, text: string): Promise<void> {
  const current = select(ctx).input?.text ?? "";
  for (let index = 0; index < current.length; index += 1) await pressKey(ctx, "Backspace");
  await typeText(ctx, text);
  await settle(ctx);
  expect(select(ctx).input?.text).toBe(text);
}

async function openNewThread(ctx: World): Promise<void> {
  await pressKey(ctx, "Ctrl+N");
  await settle(ctx);
  expect(composer(ctx).newThread).not.toBeNull();
}

const footerText = (ctx: World, name: string) => String(findObject(ctx, name).get("text"));

// --- Footer ----------------------------------------------------------------

step(
  "the composer shows the model, then the effort, then plan or build, then the access level",
  async (ctx: World) => {
    await settle(ctx);
    await snapshot(ctx);
    const xs = ["composerModel", "composerEffort", "composerMode", "composerAccess"].map((name) => {
      const box = geometry(findObject(ctx, name));
      expect(box.visible).toBe(true);
      return box.x;
    });
    expect([...xs].sort((a, b) => a - b)).toEqual(xs);
    expect(new Set(xs).size).toBe(4);
    expect(footerText(ctx, "composerModel")).toContain("gpt-5");
    expect(footerText(ctx, "composerEffort")).toContain("medium");
    expect(footerText(ctx, "composerMode")).toContain("Build");
    expect(footerText(ctx, "composerAccess")).toContain("Full access");
  },
);

step("the conversation column is narrow", async (ctx: World) => {
  await resize(ctx, 60);
  await settle(ctx);
});

step("only the primary controls are shown in the composer", async (ctx: World) => {
  await snapshot(ctx);
  expect(composer(ctx).compact).toBe(true);
  for (const name of ["composerModel", "composerPrimaryAction"]) {
    expect(geometry(findObject(ctx, name)).visible).toBe(true);
  }
  for (const name of ["composerEffort", "composerMode", "composerAccess"]) {
    expect(geometry(findObject(ctx, name)).visible).toBe(false);
  }
});

step("the rest are reachable from the command palette", async (ctx: World) => {
  await pressKey(ctx, "Ctrl+K");
  await settle(ctx);
  const titles = palette(ctx).commands.map((command) => command.title);
  expect(titles).toEqual(
    expect.arrayContaining([
      "Change reasoning effort",
      "Switch to plan mode",
      "Change runtime access",
    ]),
  );
});

// --- Plan and build --------------------------------------------------------

const MODE = { plan: "plan", build: "default" } as const;

// Given: the thread is (made) in that mode. Then: the composer and the server agree.
step(/^the thread is in (plan|build) mode$/, async (ctx: World, name: "plan" | "build") => {
  const mode = MODE[name];
  if (ctx.stepType !== "Outcome") {
    if (composer(ctx).interactionMode !== mode) {
      await updateThread(ctx, (detail) => ({ ...detail, interactionMode: mode }));
    }
    expect(composer(ctx).interactionMode).toBe(mode);
    return;
  }
  await settle(ctx);
  expect(composer(ctx).interactionMode).toBe(mode);
  expect(ctx.fake!.currentThread("t1")?.interactionMode).toBe(mode);
  expect(footerText(ctx, "composerMode")).toContain(name === "plan" ? "Plan" : "Build");
});

step("the user switches to plan mode and the server rejects it", async (ctx: World) => {
  ctx.fake!.override("setInteractionMode", () => Promise.reject(new Error("not allowed")));
  await pressKey(ctx, "Ctrl+B");
  await settle(ctx);
  expect(callsTo(ctx, "setInteractionMode").map((call) => call.args[1])).toEqual(["plan"]);
});

step("the composer shows build mode again", async (ctx: World) => {
  await snapshot(ctx);
  expect(composer(ctx).interactionMode).toBe("default");
  expect(footerText(ctx, "composerMode")).toContain("Build");
});

step("the status line shows the error", async (ctx: World) => {
  await settle(ctx);
  expect(String(findObject(ctx, "statusText").get("text"))).toContain("mode change failed");
});

// --- Pickers ---------------------------------------------------------------

step("the user opens the runtime access picker", async (ctx: World) => {
  await pressKey(ctx, "Ctrl+O");
  await settle(ctx);
  expect(select(ctx).kind).toBe("runtime");
});

step("{string} is offered", async (ctx: World, label: string) => {
  await settle(ctx);
  expect(select(ctx).options.map((option) => option.label)).toContain(label);
  expect(await snapshot(ctx)).toContain(label);
});

step("one provider is disabled and another is unavailable", async (ctx: ControlsWorld) => {
  await restartClient(ctx, {
    providers: [
      ...PROVIDERS,
      {
        instanceId: "cursor",
        driver: "cursor",
        displayName: "Cursor",
        enabled: false,
        models: [{ slug: "composer-1", name: "Composer 1", isCustom: false, capabilities: null }],
      },
      {
        instanceId: "opencode",
        driver: "opencode",
        displayName: "OpenCode",
        enabled: true,
        availability: "unavailable",
        models: [{ slug: "grok-code", name: "Grok Code", isCustom: false, capabilities: null }],
      },
    ] as unknown as ReadonlyArray<ServerProvider>,
  });
});

async function openModelPicker(ctx: World): Promise<void> {
  await pressKey(ctx, "Ctrl+Shift+M");
  await settle(ctx);
  expect(select(ctx)).toMatchObject({ open: true, kind: "model", status: "ready" });
}

step("the user opens the model picker", openModelPicker);

step("the model picker is open", openModelPicker);

step("neither provider's models are listed", async (ctx: World) => {
  const listed = select(ctx).options;
  expect(listed.map((option) => option.description)).not.toContain("Cursor");
  expect(listed.map((option) => option.description)).not.toContain("OpenCode");
  expect(listed.map((option) => option.label)).toEqual(["GPT-5", "GPT-5 Codex", "Opus"]);
  const text = await snapshot(ctx);
  expect(text).not.toContain("Composer 1");
  expect(text).not.toContain("Grok Code");
});

step("a provider's models change on the server", async (ctx: ControlsWorld) => {
  await openModelPicker(ctx);
  await pressKey(ctx, "Esc");
  const [codex, claude] = PROVIDERS as unknown as [ServerProvider, ServerProvider];
  const updated = [
    codex,
    {
      ...claude,
      models: [
        ...claude.models,
        { slug: "sonnet", name: "Sonnet", isCustom: false, capabilities: null },
      ],
    },
  ] as unknown as ReadonlyArray<ServerProvider>;
  ctx.fake!.override("listModels", async () => flattenModelOptions(updated) as never);
  ctx.booted = ctx.app;
});

step(
  "the model picker lists the new models without restarting the client",
  async (ctx: ControlsWorld) => {
    await openModelPicker(ctx);
    expect(ctx.app).toBe(ctx.booted);
    expect(select(ctx).options.map((option) => option.label)).toContain("Sonnet");
    expect(await snapshot(ctx)).toContain("Sonnet");
  },
);

step("the user picks a model with a reasoning setting", async (ctx: World) => {
  await openModelPicker(ctx);
  await chooseInPicker(ctx, "GPT-5 Codex");
});

step("the model's default effort is selected", async (ctx: World) => {
  await snapshot(ctx);
  expect(composer(ctx).selectedModel).toBe("gpt-5-codex");
  expect(composer(ctx).effort).toBe("high");
  expect(footerText(ctx, "composerEffort")).toContain("high");
});

step("a model with effort and other options set", async (ctx: World) => {
  await updateThread(ctx, (detail) => ({
    ...detail,
    modelSelection: {
      instanceId: "codex",
      model: "gpt-5",
      options: [
        { id: "reasoningEffort", value: "low" },
        { id: "fastMode", value: true },
      ],
    } as unknown as OrchestrationThread["modelSelection"],
  }));
  expect(composer(ctx).effort).toBe("low");
  expect(composer(ctx).options.find((option) => option.id === "fastMode")?.value).toBe(true);
});

step("the user changes the effort", async (ctx: World) => {
  await pressKey(ctx, "Ctrl+Shift+E");
  await settle(ctx);
  expect(select(ctx).kind).toBe("reasoning");
  await chooseInPicker(ctx, "High");
});

step("the other options are unchanged", async (ctx: World) => {
  expect(composer(ctx).effort).toBe("high");
  expect(composer(ctx).options.find((option) => option.id === "fastMode")?.value).toBe(true);
  await typeIntoPrompt(ctx, "Carry on");
  await pressKey(ctx, "Enter");
  await settle(ctx);
  const sent = callsTo(ctx, "sendReply");
  expect(sent).toHaveLength(1);
  expect((sent[0]!.args[3] as { options: unknown }).options).toEqual(
    expect.arrayContaining([
      { id: "reasoningEffort", value: "high" },
      { id: "fastMode", value: true },
    ]),
  );
});

step("the user changed the model, the effort and switched to plan mode", async (ctx: World) => {
  await openModelPicker(ctx);
  await chooseInPicker(ctx, "GPT-5 Codex");
  await pressKey(ctx, "Ctrl+Shift+E");
  await chooseInPicker(ctx, "Low");
  await pressKey(ctx, "Ctrl+B");
  await settle(ctx);
  expect(composer(ctx)).toMatchObject({
    selectedModel: "gpt-5-codex",
    effort: "low",
    interactionMode: "plan",
  });
});

step("the user sends the next reply", async (ctx: World) => {
  await typeIntoPrompt(ctx, "Plan the migration");
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("the reply is sent with that model, effort and plan mode", async (ctx: World) => {
  const sent = callsTo(ctx, "sendReply");
  expect(sent).toHaveLength(1);
  const [detail, text, , model] = sent[0]!.args as [
    OrchestrationThread,
    string,
    unknown,
    { instanceId: string; model: string; options?: unknown },
  ];
  expect(text).toBe("Plan the migration");
  expect(detail.interactionMode).toBe("plan");
  expect(model).toMatchObject({ instanceId: "codex", model: "gpt-5-codex" });
  expect(model.options).toEqual([{ id: "reasoningEffort", value: "low" }]);
});

step("the user clicks the model control again", async (ctx: World) => {
  await clickObject(ctx, "composerModel");
});

step("the model picker closes", async (ctx: World) => {
  expect(select(ctx).open).toBe(false);
  expect(ctx.host!.state.get("mode")).toBe("compose");
  expect(geometry(findObject(ctx, "selectOverlay")).visible).toBe(false);
});

// --- New-thread drafts -----------------------------------------------------

const SHOP = { ...project, title: "shop", workspaceRoot: "/work/shop" };

step(
  "the selected thread is in {string} on a worktree",
  async (ctx: ControlsWorld, title: string) => {
    await restartClient(ctx, {
      shellSnapshot: shell(undefined, [{ ...SHOP, title }] as never),
      detail: { ...thread(), branch: "feature/x", worktreePath: "/work/shop-x" },
      listRefs: async () =>
        refsResult([
          { name: "main", current: true, isDefault: true, worktreePath: null },
          { name: "feature/x", current: false, isDefault: false, worktreePath: "/work/shop-x" },
        ] as never),
    });
  },
);

step(
  "the new-thread draft uses {string} and the same workspace",
  async (ctx: World, title: string) => {
    await settle(ctx);
    expect(composer(ctx).newThread).toMatchObject({
      projectTitle: title,
      workspaceMode: "current",
      branch: "feature/x",
      worktreePath: "/work/shop-x",
    });
    expect(footerText(ctx, "composerWorkspace")).toContain("shop");
  },
);

step(
  "no thread is selected and the server default is a new worktree",
  async (ctx: ControlsWorld) => {
    await restartClient(ctx, {
      shellSnapshot: shell([] as never),
      getServerConfig: async () =>
        ({ settings: { ...DEFAULT_SERVER_SETTINGS, defaultThreadEnvMode: "worktree" } }) as never,
      listRefs: async () => refsResult(REFS),
    });
  },
);

step("the user starts a new thread", async (ctx: World) => {
  await pressKey(ctx, "Ctrl+N");
  await settle(ctx);
});

step("a new worktree from the current branch is preselected", async (ctx: World) => {
  expect(composer(ctx).newThread).toMatchObject({
    workspaceMode: "new-worktree",
    branch: "main",
  });
});

step(/^a new-thread draft ([^"]+)$/, async (ctx: ControlsWorld, gap: string) => {
  switch (gap) {
    case "with no project":
      await restartClient(ctx, { shellSnapshot: shell([] as never, [] as never) });
      await openNewThread(ctx);
      expect(composer(ctx).newThread?.projectId).toBeNull();
      await typeIntoPrompt(ctx, (ctx.draftText = "Add caching"));
      return;
    case "with an empty task":
      await openNewThread(ctx);
      ctx.draftText = "";
      return;
    case "with no model":
      await restartClient(ctx, {
        shellSnapshot: shell(undefined, [{ ...project, defaultModelSelection: null }] as never),
        detail: { ...thread(), modelSelection: null } as unknown as OrchestrationThread,
        listModels: async () => [],
      });
      await openNewThread(ctx);
      await typeIntoPrompt(ctx, (ctx.draftText = "Add caching"));
      return;
    case "for a new worktree with no base":
      await restartClient(ctx, {
        detail: { ...thread(), branch: null } as unknown as OrchestrationThread,
        listRefs: async () => refsResult([]),
      });
      await openNewThread(ctx);
      await runPaletteCommand(ctx, "Change workspace");
      await chooseInPicker(ctx, "New worktree");
      expect(composer(ctx).newThread).toMatchObject({
        workspaceMode: "new-worktree",
        branch: null,
      });
      await typeIntoPrompt(ctx, (ctx.draftText = "Add caching"));
      return;
    case "for a new worktree":
      ctx.fake!.override("listRefs", async () => refsResult(REFS));
      await openNewThread(ctx);
      await runPaletteCommand(ctx, "Change workspace");
      await chooseInPicker(ctx, "New worktree");
      expect(composer(ctx).newThread?.workspaceMode).toBe("new-worktree");
      return;
    case "on the current checkout":
      ctx.fake!.override("listRefs", async () => refsResult(REFS));
      await openNewThread(ctx);
      expect(composer(ctx).newThread).toMatchObject({ workspaceMode: "current", branch: "main" });
      return;
    case "with a task and an attached image":
      await openNewThread(ctx);
      await typeIntoPrompt(ctx, "Add caching");
      ctx.host!.dispatch("composer.attach", { path: "logo.png" });
      await settle(ctx);
      expect(composer(ctx).attachments.map((image) => image.name)).toEqual(["logo.png"]);
      return;
    default:
      throw new Error(`unknown new-thread draft "${gap}"`);
  }
});

step("a new-thread draft with the task {string}", async (ctx: ControlsWorld, task: string) => {
  await openNewThread(ctx);
  await typeIntoPrompt(ctx, (ctx.draftText = task));
});

step("the draft is kept", async (ctx: ControlsWorld) => {
  await settle(ctx);
  expect(composer(ctx).newThread).not.toBeNull();
  if (ctx.draftText !== undefined) expect(composer(ctx).text).toBe(ctx.draftText);
  expect(callsTo(ctx, "createThread")).toHaveLength(0);
});

step(
  "the user chooses the base branch {string} and sends the task",
  async (ctx: World, branch: string) => {
    await runPaletteCommand(ctx, "Change base branch");
    await chooseInPicker(ctx, branch);
    await typeIntoPrompt(ctx, "Add caching");
    await pressKey(ctx, "Enter");
    await settle(ctx);
  },
);

step("the worktree is created from {string}", async (ctx: World, branch: string) => {
  const created = callsTo(ctx, "createThread");
  expect(created).toHaveLength(1);
  expect(created[0]!.args[0]).toMatchObject({
    branch,
    createWorktree: true,
    worktreePath: null,
    firstMessage: "Add caching",
  });
});

step("the current checkout does not change", async (ctx: World) => {
  expect(callsTo(ctx, "switchRef")).toHaveLength(0);
});

step("the branch {string} is checked out in a worktree", async (ctx: World, branch: string) => {
  expect(REFS.find((ref) => ref.name === branch)?.worktreePath).toBeTruthy();
  ctx.fake!.override("listRefs", async () => refsResult(REFS));
});

step(
  "the user chooses {string} for a new-thread draft on the current workspace",
  async (ctx: World, branch: string) => {
    await openNewThread(ctx);
    expect(composer(ctx).newThread?.workspaceMode).toBe("current");
    await runPaletteCommand(ctx, "Change branch");
    await chooseInPicker(ctx, branch);
  },
);

step("the draft uses that existing worktree", async (ctx: World) => {
  expect(composer(ctx).newThread).toMatchObject({
    workspaceMode: "current",
    branch: "feature/x",
    worktreePath: "/workspace/project-one-x",
  });
  expect(callsTo(ctx, "switchRef")).toHaveLength(0);
});

step(
  "the user chooses the branch {string} and sends the task",
  async (ctx: World, branch: string) => {
    await runPaletteCommand(ctx, "Change branch");
    await chooseInPicker(ctx, branch);
    await typeIntoPrompt(ctx, "Add caching");
    await pressKey(ctx, "Enter");
    await settle(ctx);
  },
);

step(
  "the checkout switches to {string} before the thread starts",
  async (ctx: World, branch: string) => {
    const methods = ctx.fake!.calls.map((call) => call.method);
    const switched = methods.indexOf("switchRef");
    const created = methods.indexOf("createThread");
    expect(switched).toBeGreaterThanOrEqual(0);
    expect(created).toBeGreaterThan(switched);
    expect(callsTo(ctx, "switchRef")[0]!.args).toEqual([project.workspaceRoot, branch]);
    expect(callsTo(ctx, "createThread")[0]!.args[0]).toMatchObject({
      branch,
      createWorktree: false,
    });
  },
);

step("the checkout is switching branches for a new-thread draft", async (ctx: ControlsWorld) => {
  ctx.fake!.override("listRefs", async () => refsResult(REFS));
  ctx.fake!.override("switchRef", () => new Promise<never>(() => {}));
  ctx.held = (ctx.held ?? 0) + 1;
  await openNewThread(ctx);
  await runPaletteCommand(ctx, "Change branch");
  await chooseInPicker(ctx, "develop");
  expect(composer(ctx).newThread?.switching).toBe(true);
  ctx.draftText = "";
});

step("the task and the image are cleared", async (ctx: World) => {
  await settle(ctx);
  expect(composer(ctx).text).toBe("");
  expect(composer(ctx).attachments).toHaveLength(0);
  expect(String(findObject(ctx, "composerInput").get("text"))).toBe("");
});

step(
  "the user presses {string} twice and creation fails",
  async (ctx: ControlsWorld, key: string) => {
    let fail!: (error: Error) => void;
    ctx.fake!.override(
      "createThread",
      () =>
        new Promise<never>((_, reject) => {
          fail = reject;
        }),
    );
    await pressKey(ctx, key);
    await pressKey(ctx, key);
    fail(new Error("server unavailable"));
    await settle(ctx);
    expect(status(ctx)).toContain("create failed");
  },
);

step("only one creation request was made", async (ctx: World) => {
  expect(callsTo(ctx, "createThread")).toHaveLength(1);
});

// --- Adding projects -------------------------------------------------------

/** The server answers `createProject` by adding it to the shell. */
function acceptNewProjects(ctx: World): void {
  const fake = ctx.fake!;
  const added = [project] as Array<Record<string, unknown>>;
  fake.override("createProject", async (path: string) => {
    const title = path.split("/").filter(Boolean).pop() ?? path;
    added.push({ ...project, id: "p-new", title, workspaceRoot: path });
    fake.emitShell(shell(undefined, added as never));
    return "p-new" as never;
  });
}

async function addLocalFolder(ctx: World, path: string): Promise<void> {
  await runPaletteCommand(ctx, "Add project");
  expect(select(ctx).kind).toBe("project-source");
  await chooseInPicker(ctx, "Local folder");
  expect(select(ctx).kind).toBe("project-path");
  await fillPickerInput(ctx, path);
  await pressKey(ctx, "Enter");
  await settle(ctx);
}

step("the user adds the local folder {string} as a project", async (ctx: World, path: string) => {
  acceptNewProjects(ctx);
  await addLocalFolder(ctx, path);
  expect(callsTo(ctx, "createProject").map((call) => call.args[0])).toEqual([path]);
});

step("{string} is added and a new-thread draft opens in it", async (ctx: World, title: string) => {
  await settle(ctx);
  expect(composer(ctx).newThread?.projectTitle).toBe(title);
  expect(status(ctx)).toContain("Project added");
  expect(select(ctx).open).toBe(false);
});

step("the user adds a project from a Git URL", async (ctx: ControlsWorld) => {
  acceptNewProjects(ctx);
  await runPaletteCommand(ctx, "Add project");
  await chooseInPicker(ctx, "Git URL");
  expect(select(ctx).kind).toBe("project-url");
  await typeText(ctx, "https://github.com/acme/shop.git");
  await pressKey(ctx, "Enter");
  await settle(ctx);
});

step("the client asks where to clone it", async (ctx: World) => {
  await snapshot(ctx);
  expect(select(ctx)).toMatchObject({ open: true, kind: "project-destination" });
  expect(status(ctx)).toBe("Choose where to clone the repository.");
});

step(
  "the status line says {string} until the project is added",
  async (ctx: ControlsWorld, text: string) => {
    let finish!: (value: never) => void;
    ctx.fake!.override(
      "cloneRepository",
      (remoteUrl: string, destination: string) =>
        new Promise((resolve) => {
          finish = resolve as never;
          ctx.release = () => resolve({ cwd: destination, remoteUrl, repository: null } as never);
        }),
    );
    void finish;
    ctx.held = (ctx.held ?? 0) + 1;
    await fillPickerInput(ctx, "~/code/shop");
    await pressKey(ctx, "Enter");
    await settle(ctx);
    expect(callsTo(ctx, "cloneRepository").map((call) => call.args)).toEqual([
      ["https://github.com/acme/shop.git", "~/code/shop"],
    ]);
    expect(String(findObject(ctx, "statusText").get("text"))).toContain(text);
    await pressKey(ctx, "Enter");
    await settle(ctx);
    expect(callsTo(ctx, "cloneRepository")).toHaveLength(1);
    expect(status(ctx)).toBe(text);
    ctx.release!();
    ctx.held -= 1;
    await settle(ctx);
    expect(callsTo(ctx, "createProject").map((call) => call.args[0])).toEqual(["~/code/shop"]);
    expect(status(ctx)).toContain("Project added");
  },
);

step("{string} is already a project", async (ctx: ControlsWorld, path: string) => {
  await restartClient(ctx, {
    shellSnapshot: shell(undefined, [
      project,
      { ...project, id: "p-shop", title: "shop", workspaceRoot: path },
    ] as never),
  });
});

step("the user adds {string} again", async (ctx: World, path: string) => {
  await addLocalFolder(ctx, path);
  expect(callsTo(ctx, "createProject")).toHaveLength(0);
});

void PNG;
