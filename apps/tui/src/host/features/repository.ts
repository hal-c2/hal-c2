import type { SourceControlProviderKind, ThreadId } from "@hal-c2/contracts";
import * as Option from "effect/Option";

import { errorText, type Feature, type FeatureKit } from "./kit.ts";

const NEW = "__new__";

/**
 * The repository behind the open thread, beyond the panel's stacked actions:
 * branches (switch, create), worktrees (create, remove), a pull request
 * checked out from any reference, `init`, the providers the server found, and
 * publishing to one. Each is a palette command that asks what it needs.
 */
export function createRepositoryFeature(kit: FeatureKit): Feature {
  const { client, store } = kit;
  const cwd = () => kit.workspace()?.cwd ?? null;
  const status = () => store.getState().vcsStatus;
  const isRepo = () => status()?.isRepo === true;

  const report = <T>(promise: Promise<T>, done: (value: T) => string, failed: string) =>
    kit.track(
      promise.then(
        (value) => kit.status(done(value), "success"),
        (error: unknown) => kit.status(`${failed}: ${errorText(error)}`, "error"),
      ),
    );

  // --- branches --------------------------------------------------------------

  const switchRef = () => {
    const where = cwd();
    if (!where) return;
    void kit.track(
      client.listRefs(where).then(
        (listed) =>
          kit.menu({
            title: "branch",
            searchable: true,
            options: [
              {
                label: "＋ New branch…",
                description: `Create it from ${status()?.refName ?? "the current commit"} and switch to it.`,
                value: NEW,
              },
              ...listed.refs
                .filter((ref) => ref.isRemote !== true)
                .map((ref) => ({
                  label: ref.name,
                  description: ref.current
                    ? "current"
                    : ref.worktreePath
                      ? `in a worktree: ${ref.worktreePath}`
                      : "local branch",
                  value: ref.name,
                })),
            ],
            index: 1,
            onChoose: (name) => {
              if (name !== NEW) {
                void report(
                  client.switchRef(where, name),
                  () => `Switched to ${name}.`,
                  "Switch failed",
                );
                return;
              }
              kit.ask({
                label: "new branch",
                placeholder: "Like fix/login",
                onSubmit: (branch) => {
                  if (branch === "") return;
                  void report(
                    client.createRef(where, branch),
                    (created) => `Created ${created} and switched to it.`,
                    "Could not create the branch",
                  );
                },
              });
            },
          }),
        (error: unknown) => kit.status(`Could not list branches: ${errorText(error)}`, "error"),
      ),
    );
  };

  // --- worktrees -------------------------------------------------------------

  const worktrees = () => {
    const where = cwd();
    if (!where) return;
    void kit.track(
      client.listRefs(where).then(
        (listed) => {
          const existing = listed.refs.filter((ref) => ref.worktreePath !== null);
          kit.menu({
            title: "worktrees",
            searchable: true,
            options: [
              {
                label: "＋ New worktree…",
                description: `A new branch off ${status()?.refName ?? "the current branch"}, in its own folder.`,
                value: NEW,
              },
              ...existing.map((ref) => ({
                label: ref.name,
                description: ref.worktreePath!,
                value: ref.worktreePath!,
              })),
            ],
            onChoose: (value) => {
              if (value === NEW) {
                kit.ask({
                  label: "worktree branch",
                  placeholder: "The branch the worktree is created for",
                  onSubmit: (branch) => {
                    if (branch === "") return;
                    void report(
                      client.createWorktree(where, status()?.refName ?? "HEAD", branch),
                      (worktree) => `Worktree for ${worktree.refName} at ${worktree.path}.`,
                      "Could not create the worktree",
                    );
                  },
                });
                return;
              }
              const ref = existing.find((candidate) => candidate.worktreePath === value);
              kit.menu({
                title: `worktree ${ref?.name ?? value}`,
                options: [
                  { label: "Keep it", description: value, value: "keep" },
                  {
                    label: "Remove the worktree",
                    description: `Deletes ${value}; the branch ${ref?.name ?? ""} stays.`,
                    value: "remove",
                  },
                ],
                onChoose: (choice) => {
                  if (choice !== "remove") return;
                  void report(
                    client.removeWorktree(where, value),
                    () => `Removed the worktree at ${value}; ${ref?.name ?? "its branch"} is kept.`,
                    "Could not remove the worktree",
                  );
                },
              });
            },
          });
        },
        (error: unknown) => kit.status(`Could not list worktrees: ${errorText(error)}`, "error"),
      ),
    );
  };

  // --- pull requests -----------------------------------------------------------

  const checkOutPullRequest = () => {
    const workspace = kit.workspace();
    if (!workspace) return;
    kit.ask({
      label: "pull request",
      placeholder: "A URL, #42, or a gh pr checkout line",
      onSubmit: (reference) => {
        if (reference === "") return;
        kit.status("Resolving the pull request…", "busy");
        void kit.track(
          client.resolvePullRequest(workspace.cwd, reference).then(
            (pullRequest) => {
              kit.status(`#${pullRequest.number} ${pullRequest.title}`, "info");
              kit.menu({
                title: `#${pullRequest.number} ${pullRequest.title}`,
                options: [
                  {
                    label: "Check out here",
                    description: `Switch this checkout to ${pullRequest.headBranch}.`,
                    value: "local",
                  },
                  {
                    label: "Check out in a worktree",
                    description: "Leave this checkout as it is.",
                    value: "worktree",
                  },
                ],
                onChoose: (mode) =>
                  void report(
                    client.preparePullRequest({
                      cwd: workspace.cwd,
                      reference,
                      mode: mode as "local" | "worktree",
                      threadId: workspace.threadId as ThreadId,
                    }),
                    (prepared) =>
                      `#${prepared.pullRequest.number} is on ${prepared.branch}${prepared.worktreePath ? ` in ${prepared.worktreePath}` : ""}${prepared.isOnPullRequestHead ? "." : " (behind the pull request: local changes kept)."}`,
                    "Checkout failed",
                  ),
              });
            },
            (error: unknown) =>
              kit.status(`No pull request for "${reference}": ${errorText(error)}`, "error"),
          ),
        );
      },
    });
  };

  // --- providers and publishing ------------------------------------------------

  const discover = () => client.discoverSourceControl();

  const showProviders = () => {
    void kit.track(
      discover().then(
        (found) =>
          kit.menu({
            title: "source control",
            options: [...found.versionControlSystems, ...found.sourceControlProviders].map(
              (item) => {
                const version = Option.getOrNull(item.version);
                const installed =
                  item.status === "available"
                    ? `installed${version ? ` ${version}` : ""}`
                    : `not installed: ${item.installHint}`;
                const auth =
                  "auth" in item
                    ? item.auth.status === "authenticated"
                      ? ` · signed in${Option.isSome(item.auth.account) ? ` as ${item.auth.account.value}` : ""}`
                      : item.auth.status === "unauthenticated"
                        ? " · signed out"
                        : " · sign-in unknown"
                    : "";
                return { label: item.label, description: `${installed}${auth}`, value: item.kind };
              },
            ),
            onChoose: () => {},
          }),
        (error: unknown) => kit.status(`Could not read providers: ${errorText(error)}`, "error"),
      ),
    );
  };

  const publish = () => {
    const where = cwd();
    if (!where) return;
    void kit.track(
      discover().then((found) => {
        const signedIn = found.sourceControlProviders.filter(
          (provider) => provider.status === "available" && provider.auth.status === "authenticated",
        );
        if (signedIn.length === 0) {
          kit.status("No source provider is signed in on the server.", "error");
          return;
        }
        const askRepository = (provider: SourceControlProviderKind) =>
          kit.ask({
            label: "repository",
            placeholder: "owner/name",
            onSubmit: (repository) => {
              if (repository === "") return;
              kit.menu({
                title: `publish ${repository}`,
                options: [
                  {
                    label: "Private",
                    description: "Only you and people you invite.",
                    value: "private",
                  },
                  { label: "Public", description: "Anyone can see it.", value: "public" },
                ],
                onChoose: (visibility) =>
                  void report(
                    client.publishRepository({
                      cwd: where as never,
                      provider,
                      repository: repository as never,
                      visibility: visibility as never,
                    }),
                    (result) =>
                      `Published to ${result.repository.url}; ${result.remoteName} is ${result.remoteUrl}.`,
                    "Publish failed",
                  ),
              });
            },
          });
        if (signedIn.length === 1) askRepository(signedIn[0]!.kind);
        else {
          kit.menu({
            title: "publish to",
            options: signedIn.map((provider) => ({ label: provider.label, value: provider.kind })),
            onChoose: (kind) => askRepository(kind as SourceControlProviderKind),
          });
        }
      }),
    );
  };

  return {
    commands: () => {
      if (cwd() === null) return [];
      const repo = isRepo();
      return [
        ...(repo
          ? [
              {
                id: "repo.switch",
                title: "Switch or create a branch…",
                keywords: "ref checkout",
                action: "repo.switch",
              },
              { id: "repo.worktrees", title: "Worktrees…", action: "repo.worktrees" },
              {
                id: "repo.pullRequest",
                title: "Check out a pull request…",
                keywords: "pr review url",
                action: "repo.pullRequest",
              },
            ]
          : [
              {
                id: "repo.init",
                title: "Initialize a repository",
                keywords: "init version control",
                action: "repo.init",
              },
            ]),
        ...(repo && status()?.hasPrimaryRemote === false
          ? [
              {
                id: "repo.publish",
                title: "Publish repository…",
                keywords: "remote origin github create",
                action: "repo.publish",
              },
            ]
          : []),
        {
          id: "repo.providers",
          title: "Source-control providers",
          keywords: "github gitlab gh installed signed in",
          action: "repo.providers",
        },
      ];
    },
    dispatch: (action) => {
      switch (action) {
        case "repo.switch":
          switchRef();
          return true;
        case "repo.worktrees":
          worktrees();
          return true;
        case "repo.pullRequest":
          checkOutPullRequest();
          return true;
        case "repo.init": {
          const where = cwd();
          if (where) {
            void report(
              client.initRepository(where),
              () => "Repository initialized.",
              "Could not initialize a repository",
            );
          }
          return true;
        }
        case "repo.providers":
          showProviders();
          return true;
        case "repo.publish":
          publish();
          return true;
        default:
          return false;
      }
    },
  };
}
