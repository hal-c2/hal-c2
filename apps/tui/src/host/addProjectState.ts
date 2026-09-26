// Adding a project (palette → Add project), host side: pick a source, then a
// local folder to register, or a repository and the folder to clone it into.
// Port of ChatView's add-project flow and AddProjectOverlay.tsx's rows; the
// AddProject brick paints `addProject` and dispatches `project.add.*`.
import type { FilesystemBrowseResult, SourceControlDiscoveryResult } from "@hal-c2/contracts";
import {
  addProjectRemoteSourceLabel,
  buildAddProjectRemoteSourceReadiness,
  getAddProjectInitialQuery,
  getCloneDestinationPath,
  getCloneDirectoryName,
  getDefaultCloneUrl,
  normalizePastedCloneUrl,
  resolveAddProjectPath,
  sortAddProjectProviderSources,
  type AddProjectRemoteSource,
} from "@hal-c2/client-runtime/operations/projects";
import {
  filterFilesystemBrowseEntries,
  getFilesystemBrowsePath,
} from "@hal-c2/client-runtime/state/filesystem";
import {
  appendBrowsePathSegment,
  findProjectByPath,
  hasTrailingPathSeparator,
} from "@hal-c2/client-runtime/state/projects";

import type { TuiClient } from "../connection.ts";
import { clip } from "../format.ts";
import type { Store } from "../store.ts";
import { THEME } from "../theme.ts";
import { chunk, styled, type StyledText } from "./styledText.ts";

type Step = "source" | "local" | "repository" | "destination";

export interface TuiAddProjectRow {
  /** Position in the whole list, for `project.add.select`. */
  readonly index: number;
  readonly title: string;
  readonly description: string;
  /** A source that needs setup first; choosing it says what to do. */
  readonly disabled: boolean;
  readonly selected: boolean;
  /** The marker and title (and "setup required"), as AddProjectOverlay draws them. */
  readonly line: StyledText;
  /** The indented description row, when there is one. */
  readonly detail: StyledText | null;
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
  /** The list has the keys (↑/↓, Enter); otherwise the field does. Tab switches. */
  readonly listFocused: boolean;
  /** The field's text while the list has the keys: the query, else the placeholder. */
  readonly field: StyledText;
  /** What Enter does to the typed text: Select, Continue, Lookup, Add, Clone… */
  readonly actionLabel: string;
  /** "<title> ▸ <hint>" */
  readonly header: StyledText;
  readonly rows: ReadonlyArray<TuiAddProjectRow>;
  readonly status: "ready" | "loading" | "empty" | "error";
  /** The body line when there are no rows. */
  readonly message: string;
  readonly messageLine: StyledText | null;
  /** The repository being cloned, while choosing where to clone it. */
  readonly context: {
    readonly title: StyledText;
    readonly description: StyledText;
  } | null;
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
  /** The popover's inner width and the rows its content may take. */
  readonly viewport: () => { readonly width: number; readonly maxRows: number };
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
  let listFocused = true;
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
          ? `Clone ${addProjectRemoteSourceLabel(source)} owner/repository`
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
        title: entry.name,
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

  /** The highlighted row, or -1 (the typed text) when there is none. */
  const safeIndex = (count: number) =>
    count === 0 ? -1 : Math.min(Math.max(-1, index), count - 1);

  /** A folder that does not exist yet: Enter creates it (ChatView's projectWillCreatePath). */
  const willCreatePath = () =>
    isBrowseStep() &&
    browse.status !== "loading" &&
    query.trim().length > 0 &&
    (hasTrailingPathSeparator(query) ? browse.result === null : filtered().exactEntry === null);

  const publish = () => {
    const current = flow;
    const list = rows();
    const step = current?.step ?? "source";
    const source =
      current?.step === "repository" || current?.step === "destination" ? current.source : "url";
    const label = addProjectRemoteSourceLabel(source);
    const palette = THEME;
    const viewport = options.viewport();
    const labelRoom = Math.max(8, viewport.width - 8);
    const selected = safeIndex(list.length);
    const title =
      step === "source"
        ? "New project · Source"
        : step === "local"
          ? "New project · Local folder"
          : step === "repository"
            ? `New project · ${label}`
            : "New project · Clone destination";
    const placeholder =
      step === "source"
        ? "Search project sources…"
        : step === "local"
          ? "Enter or browse a project directory"
          : step === "repository"
            ? source === "url"
              ? "Enter Git clone URL"
              : `Enter ${label} owner/repository`
            : "Enter or browse the clone destination";
    const createsPath = willCreatePath();
    const actionLabel =
      step === "source"
        ? "Select"
        : step === "repository"
          ? source === "url"
            ? "Continue"
            : "Lookup"
          : step === "destination"
            ? createsPath
              ? "Create & Clone"
              : "Clone"
            : createsPath
              ? "Create & Add"
              : "Add";
    const status: TuiAddProjectState["status"] =
      step === "source"
        ? list.length > 0
          ? "ready"
          : "empty"
        : step === "repository"
          ? "empty"
          : browse.status;
    const emptyMessage =
      step === "source"
        ? "No matching project source."
        : step === "repository"
          ? source === "url"
            ? "Enter a Git clone URL and press Enter to continue."
            : "Enter a repository path and press Enter to look it up."
          : createsPath
            ? "Press Enter to create this folder and continue."
            : "No matching folders.";
    const message =
      status === "loading"
        ? "loading…"
        : status === "error"
          ? "failed to load"
          : status === "empty" || list.length === 0
            ? emptyMessage
            : "";
    const context =
      current?.step === "destination"
        ? {
            title: current.repository?.title ?? current.repositoryInput,
            description: current.repository?.description ?? current.remoteUrl,
          }
        : null;
    const hint = listFocused
      ? "↑/↓ navigate · Enter select · Tab edit · Esc back"
      : "Enter action · Tab browse · Esc back";
    // Two rows per entry, under the field, the header and (cloning) the repository.
    const windowSize = Math.max(1, Math.floor((viewport.maxRows - (context ? 3 : 0) - 3) / 2));
    const start = Math.min(
      Math.max(0, selected - Math.floor(windowSize / 2)),
      Math.max(0, list.length - windowSize),
    );
    options.publish({
      open: current !== null,
      invite: invite(),
      step,
      title,
      query,
      placeholder,
      hint,
      listFocused,
      field: styled(
        chunk(clip(query.length > 0 ? query : placeholder, labelRoom), {
          fg: query.length > 0 ? palette.text : palette.dim,
        }),
      ),
      actionLabel,
      header: styled(
        chunk(`${title} ▸ `, { fg: palette.accent }),
        chunk(hint, { fg: palette.dim }),
      ),
      rows:
        message !== ""
          ? []
          : list.slice(start, start + windowSize).map((row, offset) => {
              const rowIndex = start + offset;
              const active = rowIndex === selected;
              return {
                index: rowIndex,
                title: row.title,
                description: row.description,
                disabled: row.disabled,
                selected: active,
                line: styled(
                  chunk(active ? "▸ " : "  ", { fg: active ? palette.accent : palette.dim }),
                  chunk(clip(row.title, labelRoom), {
                    fg: row.disabled ? palette.faint : active ? palette.text : palette.dim,
                  }),
                  ...(row.disabled ? [chunk("  setup required", { fg: palette.warning })] : []),
                ),
                detail: row.description
                  ? styled(
                      chunk(`    ${clip(row.description, labelRoom)}`, {
                        fg: active ? palette.bg : palette.dim,
                      }),
                    )
                  : null,
              };
            }),
      status,
      message,
      messageLine:
        message === ""
          ? null
          : styled(chunk(message, { fg: status === "error" ? palette.error : palette.dim })),
      context: context
        ? {
            title: styled(chunk(clip(context.title, labelRoom), { fg: palette.text })),
            description: styled(chunk(clip(context.description, labelRoom), { fg: palette.dim })),
          }
        : null,
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
  /** A new step: the source list takes the keys, the others start in the field. */
  const go = (next: Flow, nextQuery: string) => {
    flow = next;
    listFocused = next.step === "source";
    setQuery(nextQuery, next.step === "source" ? 0 : -1);
  };

  const open = () => {
    if (flow) return;
    discovery = null;
    go({ step: "source" }, "");
    options.setOpen(true);
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

  /** Enter: choose the selected row, or act on the typed text (always, when forced). */
  const activateRow = (forceAction = false) => {
    const current = flow;
    if (!current || pending) return;
    const list = rows();
    const row = list[safeIndex(list.length)];
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
    if (!forceAction && row && row.kind !== "source") {
      // Into the folder, with the list keeping the keys.
      listFocused = true;
      setQuery(row.kind === "up" ? row.path : appendBrowsePathSegment(query, row.name), 0);
      return;
    }
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
          // ↑/↓ walk the list while it has the keys, wrapping at either end.
          const delta = field("delta");
          if (!flow || typeof delta !== "number" || !listFocused) return true;
          const count = rows().length;
          index =
            count === 0
              ? 0
              : index < 0
                ? delta < 0
                  ? count - 1
                  : 0
                : (index + (delta < 0 ? -1 : 1) + count) % count;
          publish();
          return true;
        }
        case "project.add.toggleFocus":
          if (!flow || flow.step === "repository") return true;
          listFocused = !listFocused;
          index = listFocused && rows().length > 0 ? 0 : -1;
          publish();
          return true;
        case "project.add.focusInput":
          if (!flow) return true;
          listFocused = false;
          index = flow.step === "source" ? 0 : -1;
          publish();
          return true;
        case "project.add.action":
          activateRow(true);
          return true;
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
    /** The popover's size changed: re-window the rows. */
    relayout: () => publish(),
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
