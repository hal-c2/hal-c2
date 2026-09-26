// @effect-diagnostics nodeBuiltinImport:off - builds real worktree layouts on disk.
import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, describe, it } from "@effect/vitest";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as Effect from "effect/Effect";

import {
  resolveGitWorktreePath,
  resolveHalC2Location,
  resolveWorktreeHalC2Home,
} from "./devHome.ts";

const makeRepo = (
  kind:
    | "worktree"
    | "checkout"
    | "bare"
    | "submodule"
    | "unreadable-git-file"
    | "bare-repo-worktree"
    | "custom-common-dir-worktree",
) =>
  Effect.acquireRelease(
    Effect.sync(() => {
      const root = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "hal-c2-devhome-"));
      if (kind === "worktree") {
        NodeFS.writeFileSync(NodePath.join(root, ".git"), "gitdir: /elsewhere/.git/worktrees/x\n");
      } else if (kind === "bare-repo-worktree") {
        // `git worktree add` from a bare repo: the common dir is `<name>.git`.
        NodeFS.writeFileSync(NodePath.join(root, ".git"), "gitdir: /srv/myrepo.git/worktrees/x\n");
      } else if (kind === "custom-common-dir-worktree") {
        // $GIT_COMMON_DIR need not be named `.git` at all.
        NodeFS.writeFileSync(NodePath.join(root, ".git"), "gitdir: /srv/store/worktrees/x\n");
      } else if (kind === "submodule") {
        NodeFS.writeFileSync(NodePath.join(root, ".git"), "gitdir: ../.git/modules/sub\n");
      } else if (kind === "unreadable-git-file") {
        NodeFS.writeFileSync(NodePath.join(root, ".git"), "not a gitdir pointer\n");
      } else if (kind === "checkout") {
        NodeFS.mkdirSync(NodePath.join(root, ".git"));
      }
      const nested = NodePath.join(root, "apps", "web", "src");
      NodeFS.mkdirSync(nested, { recursive: true });
      return { root, nested };
    }),
    ({ root }) => Effect.sync(() => NodeFS.rmSync(root, { recursive: true, force: true })),
  );

describe("resolveGitWorktreePath", () => {
  it.effect("finds a worktree root from a nested directory", () =>
    Effect.gen(function* () {
      const { root, nested } = yield* makeRepo("worktree");
      assert.equal(yield* resolveGitWorktreePath(nested), NodePath.resolve(root));
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  );

  it.effect("reports a main checkout as not a linked worktree", () =>
    Effect.gen(function* () {
      const { nested } = yield* makeRepo("checkout");
      assert.equal(yield* resolveGitWorktreePath(nested), undefined);
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  );

  it.effect("reports a directory outside a repository", () =>
    Effect.gen(function* () {
      const { nested } = yield* makeRepo("bare");
      assert.equal(yield* resolveGitWorktreePath(nested), undefined);
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  );

  it.effect("reports a submodule as not a linked worktree", () =>
    Effect.gen(function* () {
      const { nested } = yield* makeRepo("submodule");
      assert.equal(yield* resolveGitWorktreePath(nested), undefined);
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  );

  it.effect("reports a .git file without a usable gitdir pointer", () =>
    Effect.gen(function* () {
      const { nested } = yield* makeRepo("unreadable-git-file");
      assert.equal(yield* resolveGitWorktreePath(nested), undefined);
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  );

  it.effect("finds a worktree of a bare repository", () =>
    Effect.gen(function* () {
      const { root, nested } = yield* makeRepo("bare-repo-worktree");
      assert.equal(yield* resolveGitWorktreePath(nested), NodePath.resolve(root));
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  );

  it.effect("finds a worktree whose common dir is not named .git", () =>
    Effect.gen(function* () {
      const { root, nested } = yield* makeRepo("custom-common-dir-worktree");
      assert.equal(yield* resolveGitWorktreePath(nested), NodePath.resolve(root));
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  );
});

describe("resolveWorktreeHalC2Home", () => {
  it.effect("answers with .hal-c2 before the dev runner creates it", () =>
    Effect.gen(function* () {
      const { root, nested } = yield* makeRepo("worktree");
      const home = yield* resolveWorktreeHalC2Home(nested);
      assert.equal(home, NodePath.join(NodePath.resolve(root), ".hal-c2"));
      assert.isFalse(NodeFS.existsSync(home ?? ""));
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  );

  it.effect("never falls back to an existing .t3", () =>
    Effect.gen(function* () {
      const { root, nested } = yield* makeRepo("worktree");
      NodeFS.mkdirSync(NodePath.join(root, ".t3"));
      const home = yield* resolveWorktreeHalC2Home(nested);
      assert.equal(home, NodePath.join(NodePath.resolve(root), ".hal-c2"));
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  );
});

describe("resolveHalC2Location", () => {
  const homeDir = "/home/me";
  const platform = "linux" as const;

  it.effect("uses the XDG directories with the installed profile by default", () =>
    Effect.gen(function* () {
      const location = yield* resolveHalC2Location({ env: {}, homeDir, platform });
      assert.equal(location.root, undefined);
      assert.equal(location.profile, "hal-c2");
      assert.equal(location.dirs.data, "/home/me/.local/share/hal-c2");
      assert.equal(location.dirs.config, "/home/me/.config/hal-c2");
    }).pipe(Effect.provide(NodeServices.layer)),
  );

  it.effect("gives a development server with no root the hal-c2-dev profile", () =>
    Effect.gen(function* () {
      const location = yield* resolveHalC2Location({
        env: {},
        homeDir,
        platform,
        development: true,
      });
      assert.equal(location.profile, "hal-c2-dev");
      assert.equal(location.dirs.state, "/home/me/.local/state/hal-c2-dev");
    }).pipe(Effect.provide(NodeServices.layer)),
  );

  it.effect("puts every kind under HAL_C2_HOME with one profile", () =>
    Effect.gen(function* () {
      const location = yield* resolveHalC2Location({
        env: { HAL_C2_HOME: "/srv/hal-c2", XDG_DATA_HOME: "/xdg/data" },
        homeDir,
        platform,
        development: true,
      });
      assert.deepEqual(
        { root: location.root, source: location.rootSource, profile: location.profile },
        { root: "/srv/hal-c2", source: "env", profile: "hal-c2" },
      );
      assert.equal(location.dirs.data, "/srv/hal-c2/data");
    }).pipe(Effect.provide(NodeServices.layer)),
  );

  it.effect("never uses T3CODE_HOME, T3_HOME or an old home named by HAL_C2_HOME", () =>
    Effect.gen(function* () {
      const location = yield* resolveHalC2Location({
        env: { HAL_C2_HOME: "/home/me/.t3", T3CODE_HOME: "/srv/t3", T3_HOME: "/srv/t3" },
        homeDir,
        platform,
      });
      assert.equal(location.root, undefined);
      assert.equal(location.dirs.data, "/home/me/.local/share/hal-c2");
    }).pipe(Effect.provide(NodeServices.layer)),
  );

  it.effect("lets a worktree's .hal-c2 outrank HAL_C2_HOME", () =>
    Effect.gen(function* () {
      const { root, nested } = yield* makeRepo("worktree");
      const location = yield* resolveHalC2Location({
        env: { HAL_C2_HOME: "/srv/hal-c2" },
        worktreeCwd: nested,
        homeDir,
        platform,
        development: true,
      });
      const expected = NodePath.join(NodePath.resolve(root), ".hal-c2");
      assert.equal(location.root, expected);
      assert.equal(location.rootSource, "worktree");
      assert.equal(location.profile, "hal-c2");
      assert.equal(location.dirs.data, NodePath.join(expected, "data"));
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  );

  it.effect("ignores worktrees unless the caller asks", () =>
    Effect.gen(function* () {
      const location = yield* resolveHalC2Location({
        env: { HAL_C2_HOME: "/srv/hal-c2" },
        homeDir,
        platform,
      });
      assert.equal(location.rootSource, "env");
    }).pipe(Effect.provide(NodeServices.layer)),
  );

  it.effect("lets an explicit root outrank the worktree and HAL_C2_HOME", () =>
    Effect.gen(function* () {
      const { nested } = yield* makeRepo("worktree");
      const location = yield* resolveHalC2Location({
        explicitRoot: " /tmp/sandbox ",
        env: { HAL_C2_HOME: "/srv/hal-c2" },
        worktreeCwd: nested,
        homeDir,
        platform,
      });
      assert.equal(location.root, "/tmp/sandbox");
      assert.equal(location.rootSource, "explicit");
      assert.equal(location.dirs.cache, "/tmp/sandbox/cache");
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  );

  it.effect("refuses an old home as an explicit root", () =>
    Effect.gen(function* () {
      const location = yield* resolveHalC2Location({
        explicitRoot: "/home/me/.hal-c2",
        env: {},
        homeDir,
        platform,
      });
      assert.equal(location.root, undefined);
      assert.equal(location.dirs.data, "/home/me/.local/share/hal-c2");
    }).pipe(Effect.provide(NodeServices.layer)),
  );
});
