// @effect-diagnostics nodeBuiltinImport:off - builds real worktree layouts on disk.
import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, describe, it } from "@effect/vitest";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as Effect from "effect/Effect";

import {
  configuredHalC2Home,
  resolveGitWorktreePath,
  resolveHalC2Home,
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

  it.effect("keeps using an existing .t3 when the worktree has no .hal-c2", () =>
    Effect.gen(function* () {
      const { root, nested } = yield* makeRepo("worktree");
      NodeFS.mkdirSync(NodePath.join(root, ".t3"));
      const home = yield* resolveWorktreeHalC2Home(nested);
      assert.equal(home, NodePath.join(NodePath.resolve(root), ".t3"));
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  );
});

const makeHome = (dirs: ReadonlyArray<string>) =>
  Effect.acquireRelease(
    Effect.sync(() => {
      const root = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "hal-c2-userhome-"));
      for (const dir of dirs) {
        NodeFS.mkdirSync(NodePath.join(root, dir));
      }
      return root;
    }),
    (root) => Effect.sync(() => NodeFS.rmSync(root, { recursive: true, force: true })),
  );

describe("resolveHalC2Home", () => {
  it.effect("prefers HAL_C2_HOME over the legacy T3CODE_HOME and any existing home", () =>
    Effect.gen(function* () {
      const homeDir = yield* makeHome([".hal-c2", ".t3"]);
      const env = { HAL_C2_HOME: " /srv/hal-c2 ", T3CODE_HOME: "/srv/t3" };
      assert.equal(yield* resolveHalC2Home({ env, homeDir }), "/srv/hal-c2");
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  );

  it.effect("honours the legacy T3CODE_HOME when HAL_C2_HOME is unset or blank", () =>
    Effect.gen(function* () {
      const homeDir = yield* makeHome([".hal-c2"]);
      const env = { HAL_C2_HOME: "  ", T3CODE_HOME: "/srv/t3" };
      assert.equal(yield* resolveHalC2Home({ env, homeDir }), "/srv/t3");
      assert.equal(yield* configuredHalC2Home({ T3CODE_HOME: "/srv/t3" }), "/srv/t3");
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  );

  it.effect("uses an existing ~/.hal-c2 before an existing ~/.t3", () =>
    Effect.gen(function* () {
      const homeDir = yield* makeHome([".hal-c2", ".t3"]);
      assert.equal(
        yield* resolveHalC2Home({ env: {}, homeDir }),
        NodePath.join(homeDir, ".hal-c2"),
      );
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  );

  it.effect("uses an existing ~/.t3 in place when there is no ~/.hal-c2", () =>
    Effect.gen(function* () {
      const homeDir = yield* makeHome([".t3"]);
      assert.equal(yield* resolveHalC2Home({ env: {}, homeDir }), NodePath.join(homeDir, ".t3"));
      assert.isFalse(NodeFS.existsSync(NodePath.join(homeDir, ".hal-c2")));
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  );

  it.effect("defaults to ~/.hal-c2 on a fresh machine", () =>
    Effect.gen(function* () {
      const homeDir = yield* makeHome([]);
      assert.equal(
        yield* resolveHalC2Home({ env: {}, homeDir }),
        NodePath.join(homeDir, ".hal-c2"),
      );
    }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
  );
});
