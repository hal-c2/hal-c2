// Adding projects (files/adding-projects.feature). The fake environment's
// projects, folders and source-control sign-ins are set up before the client
// boots; the steps then drive the add-project flow by keys.
import { expect } from "bun:test";
import { inferProjectTitleFromPath } from "@hal-c2/client-runtime/state/projects";

import { step } from "../../steps.ts";
import type { TuiAddProjectState } from "../../../src/host/addProjectState.ts";
import type { TuiPageState } from "../../../src/host/host.ts";
import { project as fixtureProject, shell } from "../fakeClient.ts";
import { recorded } from "../threadWorld.ts";
import { chooseCommand, palette } from "../threadUi.ts";
import { boot, pressKey, settle, typeText, useClient, type World } from "../world.ts";

interface ProjectsWorld extends World {
  environment?: {
    projects: Array<{ id: string; title: string; workspaceRoot: string }>;
    /** Folders on the machine, by parent folder (with a trailing slash). */
    folders: Record<string, string[]>;
    platform: NodeJS.Platform;
    signedIn: Record<string, boolean>;
  };
}

const env = (ctx: ProjectsWorld) =>
  (ctx.environment ??= {
    projects: [
      {
        id: fixtureProject.id,
        title: fixtureProject.title,
        workspaceRoot: fixtureProject.workspaceRoot,
      },
    ],
    folders: {},
    platform: "linux",
    signedIn: {},
  });

const projectRecord = (id: string, title: string, workspaceRoot: string) => ({
  ...fixtureProject,
  id,
  title,
  workspaceRoot,
});

/** Boot against the fake environment described so far. */
async function start(ctx: ProjectsWorld) {
  if (ctx.app) return;
  const machine = env(ctx);
  const snapshot = () =>
    shell(
      machine.projects.some((candidate) => candidate.id === fixtureProject.id) ? undefined : [],
      machine.projects.map((entry) =>
        projectRecord(entry.id, entry.title, entry.workspaceRoot),
      ) as never,
    );
  const provider = (kind: string, label: string) => ({
    kind,
    label,
    status: "available",
    version: { _tag: "None" },
    installHint: `Install the ${label} CLI.`,
    detail: { _tag: "None" },
    auth: {
      status: machine.signedIn[kind] ? "authenticated" : "unauthenticated",
      account: { _tag: "None" },
      host: { _tag: "None" },
      detail: { _tag: "None" },
    },
  });
  const fake = useClient(ctx, {
    shellSnapshot: snapshot(),
    hostPlatform: machine.platform,
    browseFilesystem: async (partialPath) => {
      const directory = partialPath.endsWith("/") ? partialPath : `${partialPath}/`;
      return {
        parentPath: directory.slice(0, -1) || "/",
        entries: (machine.folders[directory] ?? []).map((name) => ({
          name,
          fullPath: `${directory}${name}`,
        })),
      } as never;
    },
    discoverSourceControl: async () =>
      ({
        versionControlSystems: [],
        sourceControlProviders: [provider("github", "GitHub"), provider("gitlab", "GitLab")],
      }) as never,
    // The server adds the project and the shell stream lists it.
    createProject: async (workspaceRoot) => {
      const id = `p-${machine.projects.length + 1}`;
      machine.projects.push({ id, title: inferProjectTitleFromPath(workspaceRoot), workspaceRoot });
      fake.emitShell(snapshot());
      return id as never;
    },
  });
  await boot(ctx);
  fake.connect();
  await settle(ctx);
}

export const flow = (ctx: World) => ctx.host!.state.get("addProject") as TuiAddProjectState;
const listed = (ctx: World) =>
  (
    ctx.host!.state.get("sidebar") as {
      projects: Array<{ displayName: string; workspaceRoot: string }>;
    }
  ).projects;

/** The palette's commands right now (opened and closed again to read them). */
async function paletteTitles(ctx: World): Promise<string[]> {
  const wasOpen = palette(ctx).open;
  if (!wasOpen) await pressKey(ctx, "Ctrl+K");
  const titles = palette(ctx).commands.map((item) => item.title);
  if (!wasOpen) await pressKey(ctx, "Esc");
  return titles;
}

export async function openAddProject(ctx: ProjectsWorld) {
  await start(ctx);
  await chooseCommand(ctx, "Add project");
  await settle(ctx);
  expect(flow(ctx).open).toBe(true);
}

/** In the source list: move to the row titled `title` and press Enter. */
export async function chooseSource(ctx: World, title: string) {
  for (let guard = 0; guard < 10; guard += 1) {
    if (flow(ctx).rows.find((row) => row.selected)?.title === title) break;
    await pressKey(ctx, "Down");
  }
  expect(flow(ctx).rows.find((row) => row.selected)?.title).toBe(title);
  await pressKey(ctx, "Enter");
  await settle(ctx);
}

/** Replace what the path field holds, as the user would: erase, then type. */
export async function fillField(ctx: World, text: string) {
  for (let left = flow(ctx).query.length; left > 0; left -= 1) await pressKey(ctx, "Backspace");
  if (text.length > 0) await typeText(ctx, text);
  await settle(ctx);
  expect(flow(ctx).query).toBe(text);
}

export async function addLocalFolder(ctx: ProjectsWorld, path: string) {
  await openAddProject(ctx);
  await chooseSource(ctx, "Local folder");
  await fillField(ctx, path);
  await pressKey(ctx, "Enter");
  await settle(ctx);
}

// --- The environment -------------------------------------------------------------

step("a connected environment {string}", (ctx: ProjectsWorld) => {
  env(ctx);
});
step("{string} has no projects", (ctx: ProjectsWorld) => {
  env(ctx).projects = [];
});
step("the folder {string} exists on {string}", (ctx: ProjectsWorld, path: string) => {
  const slash = path.lastIndexOf("/");
  (env(ctx).folders[path.slice(0, slash + 1)] ??= []).push(path.slice(slash + 1));
});
// Browsing lists folders only: the file is on disk but never listed.
step(
  "{string} holds the folders {string} and {string} and the file {string}",
  (ctx: ProjectsWorld, parent: string, first: string, second: string) => {
    env(ctx).folders[`${parent}/`] = [first, second];
  },
);
step("{string} is already a project on {string}", (ctx: ProjectsWorld, name: string) => {
  env(ctx).projects.push({ id: `p-${name}`, title: name, workspaceRoot: `/home/sam/${name}` });
});
step(
  /^"([^"]+)" runs Linux( with no active project)?$/,
  (ctx: ProjectsWorld, _name: string, noActiveProject?: string) => {
    env(ctx).platform = "linux";
    if (noActiveProject) env(ctx).projects = [];
  },
);
step("the user is signed in to GitHub on {string}", (ctx: ProjectsWorld) => {
  env(ctx).signedIn.github = true;
});
step("the user is not signed in to GitLab on {string}", (ctx: ProjectsWorld) => {
  env(ctx).signedIn.gitlab = false;
});

// --- No projects -------------------------------------------------------------------

step("the user opens the app", start);
step("the user is asked what they should work on", async (ctx: World) => {
  expect(await settle(ctx)).toContain("What should we work on?");
  expect(flow(ctx).invite).toBe(true);
});
step("the user is offered to add a project", async (ctx: World) => {
  expect(await settle(ctx)).toContain("[ Add project ]");
  expect(await paletteTitles(ctx)).toContain("Add project");
});

// --- Local folders -----------------------------------------------------------------

step("the user adds the local folder {string}", addLocalFolder);
step("the user adds the local folder of {string} again", (ctx: ProjectsWorld, name: string) =>
  addLocalFolder(ctx, `/home/sam/${name}`),
);

step("the project {string} is listed for {string}", async (ctx: World, name: string) => {
  await settle(ctx);
  expect(listed(ctx).map((entry) => entry.displayName)).toContain(name);
});
// "a draft thread opens in {string}" (threads.steps.ts) checks the new-thread draft.
step("no second project is created", async (ctx: ProjectsWorld) => {
  await settle(ctx);
  expect(recorded(ctx, "createProject")).toEqual([]);
  expect(listed(ctx).filter((entry) => entry.displayName === "shop")).toHaveLength(1);
});
step("the user is told the project was already added", async (ctx: World) => {
  // The status row cuts it to 32 cells, as the OpenTUI client does.
  const frame = await settle(ctx);
  expect((ctx.host!.state.get("status") as { text: string }).text).toBe(
    "Project already added. What should we build?",
  );
  expect(frame).toContain((ctx.host!.state.get("statusRow") as { label: string }).label);
  expect(ctx.host!.state.get("page") as TuiPageState).toMatchObject({
    kind: "draft",
    projectTitle: "shop",
  });
});

step(
  "the user types {string} while adding a local folder",
  async (ctx: ProjectsWorld, text: string) => {
    await openAddProject(ctx);
    await chooseSource(ctx, "Local folder");
    await fillField(ctx, text);
  },
);
step(
  "the folders {string} and {string} are offered",
  async (ctx: World, first: string, second: string) => {
    const frame = await settle(ctx);
    const titles = flow(ctx).rows.map((row) => row.title);
    expect(titles).toContain(first);
    expect(titles).toContain(second);
    expect(frame).toContain(first);
    expect(frame).toContain(second);
  },
);
// While adding a project: not among the rows; otherwise: not a palette command.
step("{string} is not offered", async (ctx: World, name: string) => {
  const frame = await settle(ctx);
  // An open thread menu (the machines to move to) is what is on offer.
  const menu = ctx.host!.state.get("contextMenu") as {
    rows: ReadonlyArray<{ label?: string }>;
  } | null;
  if (menu) {
    expect(menu.rows.some((row) => row.label?.includes(name))).toBe(false);
    return;
  }
  if (!flow(ctx).open) {
    expect(await paletteTitles(ctx)).not.toContain(name);
    return;
  }
  expect(
    flow(ctx)
      .rows.map((row) => row.title)
      .join("\n"),
  ).not.toContain(name);
  expect(frame).not.toContain(name);
});

// --- Cloning -----------------------------------------------------------------------

step(
  "the user adds a project from the Git URL {string}",
  async (ctx: ProjectsWorld, url: string) => {
    await openAddProject(ctx);
    await chooseSource(ctx, "Git URL");
    await fillField(ctx, url);
    await pressKey(ctx, "Enter");
    await settle(ctx);
  },
);
step("chooses {string} as the destination", async (ctx: World, path: string) => {
  expect(flow(ctx).step).toBe("destination");
  await fillField(ctx, path);
  await pressKey(ctx, "Enter");
  await settle(ctx);
});
step("the repository is cloned into {string}", (ctx: ProjectsWorld, path: string) => {
  expect(recorded(ctx, "cloneRepository")).toEqual([["https://example.com/acme/shop.git", path]]);
  expect(recorded(ctx, "createProject")).toEqual([[path]]);
});

step(
  "the user adds a project from the GitHub repository {string}",
  async (ctx: ProjectsWorld, repository: string) => {
    await openAddProject(ctx);
    await chooseSource(ctx, "GitHub repository");
    await fillField(ctx, repository);
    await pressKey(ctx, "Enter");
    await settle(ctx);
    expect(recorded(ctx, "lookupRepository")).toEqual([["github", repository]]);
  },
);
step("the user is asked where to clone the repository", async (ctx: World) => {
  const frame = await settle(ctx);
  expect(flow(ctx).step).toBe("destination");
  expect(frame).toContain("New project · Clone destination");
  expect((ctx.host!.state.get("status") as { text: string }).text).toBe(
    "Choose where to clone the repository.",
  );
  expect(frame).toContain((ctx.host!.state.get("statusRow") as { label: string }).label);
});
step("a destination folder named {string} is suggested", (ctx: World, name: string) => {
  expect(flow(ctx).query).toBe(`~/${name}`);
});

step("the user adds a project from a repository", openAddProject);
step("GitLab is marked as needing setup", async (ctx: World) => {
  const row = flow(ctx).rows.find((candidate) => candidate.title === "GitLab repository");
  expect(row?.disabled).toBe(true);
  const frame = (await settle(ctx)).split("\n");
  expect(frame.find((line) => line.includes("GitLab repository"))).toContain("  setup required");
});
step("the user is pointed to source control settings", async (ctx: World) => {
  await chooseSource(ctx, "GitLab repository");
  const status = ctx.host!.state.get("status") as { text: string };
  expect(status.text).toBe(
    "GitLab is not authenticated. Open Source Control settings for setup guidance.",
  );
  expect(flow(ctx).step).toBe("source");
});
