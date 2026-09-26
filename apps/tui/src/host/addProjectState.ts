// Adding a project (palette → Add project), host side: pick a source, then a
// local folder to register, or a repository and the folder to clone it into.
// Port of ChatView's add-project flow; the AddProject brick paints
// `addProject` and dispatches `project.add.*`.
import type { FilesystemBrowseResult, SourceControlDiscoveryResult } from "@t3tools/contracts";
import {
  addProjectRemoteSourceLabel,
  addProjectRemoteSourcePathHint,
  buildAddProjectRemoteSourceReadiness,
  getAddProjectInitialQuery,
  getCloneDestinationPath,
  getCloneDirectoryName,
  getDefaultCloneUrl,
  normalizePastedCloneUrl,
  resolveAddProjectPath,
  sortAddProjectProviderSources,
  type AddProjectRemoteSource,
} from "@t3tools/client-runtime/operations/projects";
import {
  filterFilesystemBrowseEntries,
  getFilesystemBrowsePath,
} from "@t3tools/client-runtime/state/filesystem";
import {
  appendBrowsePathSegment,
  findProjectByPath,
  hasTrailingPathSeparator,
} from "@t3tools/client-runtime/state/projects";

import type { TuiClient } from "../connection.ts";
import type { Store } from "../store.ts";

type Step = "source" | "local" | "repository" | "destination";

export interface TuiAddProjectRow {
  /** Position in the whole list, for `project.add.select`. */
  readonly index: number;
  readonly title: string;
  readonly description: string;
  /** A source that needs setup first; choosing it says what to do. */
  readonly disabled: boolean;
  readonly selected: boolean;
}

/** Published under `addProject`. */
export interface TuiAddProjectState {
  readonly open: boolean;
  /** No projects yet: the main area invites the user to add one. */
  readonly invite: boolean;
  readonly step: Step;
  readonly title: string;
  readonly query: string;
  readonly placeholder: string;
  readonly hint: string;
  readonly rows: ReadonlyArray<TuiAddProjectRow>;
  readonly status: "ready" | "loading" | "empty" | "error";
  /** The body line when there are no rows. */
  readonly message: string;
  /** The looked-up repository while choosing where to clone it. */
  readonly repository: { readonly title: string; readonly description: string } | null;
  readonly pending: boolean;
}

type Row =
  | { readonly kind: "source"; readonly source: "local" | AddProjectRemoteSource }
  | { readonly kind: "up"; readonly path: string }
  | { readonly kind: "directory"; readonly name: string };

type Flow =
  | { readonly step: "source" | "local" }
  | { readonly step: "repository"; readonly source: AddProjectRemoteSource }
  | {
      readonly step: "destination";
      readonly source: AddProjectRemoteSource;
      readonly repositoryInput: string;
      readonly repository: { readonly title: string; readonly description: string } | null;
      readonly remoteUrl: string;
    };

export interface AddProjectControllerOptions {
  readonly client: Pick<
    TuiClient,
    | "hostPlatform"
    | "browseFilesystem"
    | "discoverSourceControl"
    | "lookupRepository"
    | "cloneRepository"
    | "createProject"
  >;
  readonly store: Store;
  /** Relative paths resolve against the active project's folder. */
  readonly currentProjectCwd: () => string | null;
  /** Folder new paths start in (the add-project base directory setting). */
  readonly baseDirectory: () => string | null;
  /** Rows the overlay may take. */
  readonly height: () => number;
  readonly setOpen: (open: boolean) => void;
  /** Start a draft thread in the project that was just added or found. */
  readonly openDraft: (projectId: string) => void;
  readonly publish: (state: TuiAddProjectState) => void;
}

const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));

export function createAddProjectController(options: AddProjectControllerOptions) {
  const { client, store } = options;
  let flow: Flow | null = null;
  let query = "";
  let index = 0;
  let discovery: SourceControlDiscoveryResult | null = null;
  let browse: {
    readonly directoryPath: string;
    readonly status: TuiAddProjectState["status"];
    readonly result: FilesystemBrowseResult | null;
  } = { directoryPath: "", status: "empty", result: null };
  let generation = 0;
  let pending = false;
  let pendingProjectId: string | null = null;
  const inFlight = new Set<Promise<unknown>>();
  const track = (promise: Promise<unknown>) => {
    inFlight.add(promise);
    void promise.finally(() => inFlight.delete(promise));
  };

  const projects = () => store.getState().shell?.projects ?? [];
  const isBrowseStep = () => flow?.step === "local" || flow?.step === "destination";
  const browsePath = () => getFilesystemBrowsePath(query, client.hostPlatform, isBrowseStep());
  const filtered = () =>
    filterFilesystemBrowseEntries(browse.result?.entries ?? [], browsePath().filterQuery);

  const sourceRows = (): ReadonlyArray<
    Row & { title: string; description: string; disabled: boolean }
  > => {
    const readiness = buildAddProjectRemoteSourceReadiness(discovery);
    const needle = query.trim().toLowerCase();
    return [
      {
        kind: "source" as const,
        source: "local" as const,
        title: "Local folder",
        description: "Browse a folder on disk",
        disabled: false,
      },
      {
        kind: "source" as const,
        source: "url" as const,
        title: "Git URL",
        description: "Clone from a remote URL",
        disabled: false,
      },
      ...sortAddProjectProviderSources(readiness).map((source) => ({
        kind: "source" as const,
        source,
        title: `${addProjectRemoteSourceLabel(source)} repository`,
        description: readiness[source].ready
          ? `Clone ${addProjectRemoteSourceLabel(source)} ${addProjectRemoteSourcePathHint(source)}`
          : (readiness[source].hint ?? "Provider setup required"),
        disabled: !readiness[source].ready,
      })),
    ].filter(
      (row) =>
        needle.length === 0 ||
        row.title.toLowerCase().includes(needle) ||
        row.description.toLowerCase().includes(needle),
    );
  };
  const browseRows = () => {
    const path = browsePath();
    return [
      ...(path.canBrowseUp && path.parentPath
        ? [
            {
              kind: "up" as const,
              path: path.parentPath,
              title: "..",
              description: "",
              disabled: false,
            },
          ]
        : []),
      ...filtered().visibleEntries.map((entry) => ({
        kind: "directory" as const,
        name: entry.name,
        title: `${entry.name}/`,
        description: entry.fullPath,
        disabled: false,
      })),
    ];
  };
  const rows = () => (flow?.step === "source" ? sourceRows() : isBrowseStep() ? browseRows() : []);

  /** The typed folder: the listed folder it names, or the text itself. */
  const resolvedPath = () =>
    hasTrailingPathSeparator(query)
      ? (browse.result?.parentPath ?? query.trim())
      : (filtered().exactEntry?.fullPath ?? query.trim());

  const invite = () => store.getState().shell !== null && projects().length === 0;

  const publish = () => {
    const current = flow;
    const list = rows();
    const step = current?.step ?? "source";
    const source =
      current?.step === "repository" || current?.step === "destination" ? current.source : "url";
    const label = addProjectRemoteSourceLabel(source);
    const loading = isBrowseStep() && browse.status === "loading";
    // Border, input, header and hint take four rows; a repository card three.
    const windowSize = Math.max(1, options.height() - 4 - (step === "destination" ? 3 : 0));
    const start = Math.max(
      0,
      Math.min(index - Math.floor(windowSize / 2), list.length - windowSize),
    );
    options.publish({
      open: current !== null,
      invite: invite(),
      step,
      title:
        step === "source"
          ? "Add project"
          : step === "local"
            ? "Add project · Local folder"
            : step === "repository"
              ? `Add project · ${label}`
              : "Clone into",
      query,
      placeholder:
        step === "source"
          ? "Search sources"
          : step === "repository"
            ? source === "url"
              ? "Paste a Git URL"
              : `Enter ${label} ${addProjectRemoteSourcePathHint(source)}`
            : "Type a folder path",
      hint:
        step === "source"
          ? "↑/↓ choose · Enter select · Esc close"
          : step === "repository"
            ? "Enter look up · Esc back"
            : `↑/↓ folders · Enter ${step === "local" ? "add" : "clone"} · Esc back`,
      rows: list.slice(start, start + windowSize).map((row, offset) => ({
        index: start + offset,
        title: row.title,
        description: row.description,
        disabled: row.disabled,
        selected: start + offset === index,
      })),
      status: loading
        ? "loading"
        : isBrowseStep() && browse.status === "error"
          ? "error"
          : list.length > 0
            ? "ready"
            : "empty",
      message: loading
        ? "loading…"
        : isBrowseStep() && browse.status === "error"
          ? "failed to list folders"
          : step === "repository"
            ? ""
            : step === "source"
              ? "no matching sources"
              : "no folders",
      repository: current?.step === "destination" ? current.repository : null,
      pending,
    });
  };

  /** List the typed path's folder when it changed. */
  const refreshBrowse = () => {
    const directoryPath = isBrowseStep() ? browsePath().directoryPath : "";
    if (directoryPath === browse.directoryPath) return;
    const token = ++generation;
    if (directoryPath.length === 0) {
      browse = { directoryPath, status: "empty", result: null };
      return;
    }
    browse = { directoryPath, status: "loading", result: null };
    track(
      client.browseFilesystem(directoryPath, options.currentProjectCwd() ?? undefined).then(
        (result) => {
          if (token !== generation) return;
          browse = { directoryPath, status: result.entries.length > 0 ? "ready" : "empty", result };
          publish();
        },
        (error: unknown) => {
          if (token !== generation) return;
          browse = { directoryPath, status: "error", result: null };
          store.setStatus(`browse failed: ${errorText(error)}`, "error");
          publish();
        },
      ),
    );
  };

  const setQuery = (next: string, nextIndex: number) => {
    query = next;
    index = nextIndex;
    refreshBrowse();
    publish();
  };
  const go = (next: Flow, nextQuery: string) => {
    flow = next;
    setQuery(nextQuery, next.step === "source" ? 0 : -1);
  };

  const open = () => {
    if (flow) return;
    options.setOpen(true);
    discovery = null;
    go({ step: "source" }, "");
    const token = generation;
    track(
      client.discoverSourceControl().then(
        (result) => {
          if (!flow || token !== generation) return;
          discovery = result;
          publish();
        },
        // Local folders and Git URLs work without provider discovery.
        () => {},
      ),
    );
  };

  const close = () => {
    if (!flow) return;
    flow = null;
    query = "";
    generation += 1;
    browse = { directoryPath: "", status: "empty", result: null };
    options.setOpen(false);
    publish();
  };

  /** Selects the project and starts a draft there; false until it is listed. */
  const activate = (projectId: string): boolean => {
    if (!projects().some((project) => project.id === projectId)) return false;
    pendingProjectId = null;
    const scope = store.getState().projectScopeId;
    if (scope !== null && scope !== projectId) store.setProjectScope(projectId);
    close();
    options.openDraft(projectId);
    store.setStatus("Project added. What should we build?", "success");
    return true;
  };

  const busy = (promise: Promise<unknown>) => {
    pending = true;
    publish();
    track(
      promise.finally(() => {
        pending = false;
        publish();
      }),
    );
  };

  const register = (rawPath: string) => {
    const resolution = resolveAddProjectPath({
      rawPath,
      currentProjectCwd: options.currentProjectCwd(),
      platform: client.hostPlatform,
    });
    if (!resolution.ok) {
      store.setStatus(resolution.error, "error");
      return;
    }
    const existing = findProjectByPath(projects(), resolution.path);
    if (existing) {
      activate(existing.id);
      store.setStatus("Project already added. What should we build?", "info");
      return;
    }
    store.setStatus("Adding project…", "busy");
    busy(
      client.createProject(resolution.path).then(
        (projectId) => {
          if (activate(projectId)) return;
          pendingProjectId = projectId;
          close();
          store.setStatus("Project added. Waiting for it to appear…", "busy");
        },
        (error: unknown) => store.setStatus(`add project failed: ${errorText(error)}`, "error"),
      ),
    );
  };

  const destinationFor = (repository: string) =>
    getCloneDestinationPath(
      getAddProjectInitialQuery(options.baseDirectory()),
      getCloneDirectoryName(repository),
    );

  const submitRepository = (current: Extract<Flow, { step: "repository" }>) => {
    const repositoryInput = query.trim();
    if (repositoryInput.length === 0) {
      store.setStatus("Enter a repository or Git URL.", "error");
      return;
    }
    if (current.source === "url") {
      const remoteUrl = normalizePastedCloneUrl(repositoryInput);
      go(
        { step: "destination", source: "url", repositoryInput, repository: null, remoteUrl },
        destinationFor(remoteUrl),
      );
      store.setStatus("Choose where to clone the repository.", "info");
      return;
    }
    store.setStatus("Looking up repository…", "busy");
    busy(
      client.lookupRepository(current.source, repositoryInput).then(
        (repository) => {
          if (flow !== current) return;
          go(
            {
              step: "destination",
              source: current.source,
              repositoryInput,
              repository: {
                title: repository.nameWithOwner,
                description: getDefaultCloneUrl(repository),
              },
              remoteUrl: getDefaultCloneUrl(repository),
            },
            destinationFor(repository.nameWithOwner),
          );
          store.setStatus("Choose where to clone the repository.", "info");
        },
        (error: unknown) =>
          store.setStatus(`repository lookup failed: ${errorText(error)}`, "error"),
      ),
    );
  };

  const submitDestination = (current: Extract<Flow, { step: "destination" }>) => {
    const resolution = resolveAddProjectPath({
      rawPath: resolvedPath(),
      currentProjectCwd: options.currentProjectCwd(),
      platform: client.hostPlatform,
    });
    if (!resolution.ok) {
      store.setStatus(resolution.error, "error");
      return;
    }
    store.setStatus("Cloning repository…", "busy");
    busy(
      client.cloneRepository(current.remoteUrl, resolution.path).then(
        (result) => register(result.cwd),
        (error: unknown) => store.setStatus(`clone failed: ${errorText(error)}`, "error"),
      ),
    );
  };

  /** Enter: choose the selected row, or act on the typed text. */
  const activateRow = () => {
    const current = flow;
    if (!current || pending) return;
    const row = rows()[index];
    if (current.step === "source") {
      if (row?.kind !== "source") return;
      if (row.disabled) {
        store.setStatus(row.description, "error");
        return;
      }
      if (row.source === "local") {
        go({ step: "local" }, getAddProjectInitialQuery(options.baseDirectory()));
      } else {
        go({ step: "repository", source: row.source }, "");
      }
      return;
    }
    if (current.step === "repository") {
      submitRepository(current);
      return;
    }
    if (row?.kind === "up") return setQuery(row.path, -1);
    if (row?.kind === "directory") return setQuery(appendBrowsePathSegment(query, row.name), -1);
    if (current.step === "destination") submitDestination(current);
    else register(resolvedPath());
  };

  const back = () => {
    const current = flow;
    if (!current || pending) return;
    if (current.step === "source") close();
    else if (current.step === "destination") {
      go({ step: "repository", source: current.source }, current.repositoryInput);
    } else go({ step: "source" }, "");
  };

  publish();

  return {
    /** Handles `project.add` and `project.add.*`; false for anything else. */
    dispatch: (action: string, payload: unknown): boolean => {
      const field = (name: string) =>
        typeof payload === "object" && payload !== null
          ? (payload as Record<string, unknown>)[name]
          : undefined;
      switch (action) {
        case "project.add":
          open();
          return true;
        case "project.add.input": {
          const text = field("text");
          if (flow && typeof text === "string" && text !== query) {
            setQuery(text, flow.step === "source" ? 0 : -1);
          }
          return true;
        }
        case "project.add.move": {
          const delta = field("delta");
          if (!flow || typeof delta !== "number") return true;
          const count = rows().length;
          const min = flow.step === "source" ? 0 : -1;
          index = Math.max(min, Math.min(count - 1, index + delta));
          publish();
          return true;
        }
        case "project.add.select": {
          const rowIndex = field("index");
          if (!flow || typeof rowIndex !== "number") return true;
          index = rowIndex;
          activateRow();
          return true;
        }
        case "project.add.activate":
          activateRow();
          return true;
        case "project.add.back":
          back();
          return true;
        case "project.add.close":
          if (!pending) close();
          return true;
        default:
          return false;
      }
    },
    isOpen: () => flow !== null,
    /** The shell changed: the invite follows it, and a new project is picked up. */
    sync: () => {
      if (pendingProjectId !== null && activate(pendingProjectId)) return;
      publish();
    },
    commands: () => [{ title: "Add project", action: "project.add" }],
    settled: async () => {
      while (inFlight.size > 0) await Promise.all([...inFlight]);
    },
  };
}
