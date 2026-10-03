import type { ProjectContentMatch, ProjectSearchContentsResult } from "@hal-c2/contracts";

import type { SectionHost, SectionItem, SettingsSection } from "../settingsSections.ts";
import { errorText, plural } from "./shared.ts";

/** Matches asked for at once; the page says when there are more. */
const SEARCH_LIMIT = 200;

/**
 * Search project contents: the text typed is looked for across the workspace's
 * files (`projects.searchContents`), and the matching lines are listed under
 * their file. Enter on a match opens the file there.
 */
export function projectSearchSection(
  host: SectionHost,
  options: {
    /** The workspace to search: the open thread's, else the scoped or only project's. */
    readonly workspace: () => { readonly cwd: string; readonly label: string } | null;
    /** Open a file of the workspace at a line; false when it cannot be shown. */
    readonly openFile: (cwd: string, path: string, line: number) => boolean;
  },
): SettingsSection {
  const { client } = host;
  let query = "";
  let cwd: string | null = null;
  let label = "";
  let result: ProjectSearchContentsResult | null = null;
  let error: string | null = null;
  let searching = false;
  let generation = 0;

  const search = (text: string) => {
    query = text;
    result = null;
    error = null;
    const asked = ++generation;
    if (query === "" || cwd === null) {
      searching = false;
      host.refresh();
      return;
    }
    searching = true;
    host.refresh();
    void host.track(
      client
        .mcCall<ProjectSearchContentsResult>("projects.searchContents", {
          cwd,
          query,
          limit: SEARCH_LIMIT,
          caseSensitive: false,
          wholeWord: false,
          useRegex: false,
        })
        .then(
          (found) => {
            if (asked !== generation) return;
            searching = false;
            result = found;
            host.refresh();
            const first = found.matches[0];
            if (first) host.select(`match-${first.path}:${first.lineNumber}`);
          },
          (cause: unknown) => {
            if (asked !== generation) return;
            searching = false;
            error = errorText(cause);
            host.refresh();
          },
        ),
    );
  };

  const ask = () =>
    host.ask(
      { label: "Search for", value: query, placeholder: "text in the project's files" },
      search,
    );

  const items = (): SectionItem[] => {
    if (cwd === null) return [{ kind: "note", text: "Open a project to search its files." }];
    const list: SectionItem[] = [
      {
        kind: "row",
        id: "query",
        label: "Search for",
        value: query === "" ? "—" : query,
        run: ask,
      },
      { kind: "blank" },
    ];
    if (error !== null) list.push({ kind: "note", text: error, tone: "error" });
    else if (searching) list.push({ kind: "note", text: "Searching…" });
    else if (query === "") list.push({ kind: "note", text: "Type to search across your project." });
    else if (result && result.matches.length === 0) {
      list.push({ kind: "note", text: "No results found." });
    } else if (result) {
      const byFile = new Map<string, ProjectContentMatch[]>();
      for (const match of result.matches) {
        byFile.set(match.path, [...(byFile.get(match.path) ?? []), match]);
      }
      list.push({
        kind: "note",
        text: `${plural(result.matches.length, "result")} in ${plural(byFile.size, "file")}${
          result.truncated ? " (more not shown)" : ""
        }`,
      });
      for (const [path, matches] of byFile) {
        list.push({ kind: "heading", text: path });
        for (const match of matches) {
          list.push({
            kind: "row",
            id: `match-${match.path}:${match.lineNumber}`,
            label: `${String(match.lineNumber).padStart(4)}  ${match.lineContent.trim()}`,
            clip: true,
            run: () => {
              if (!options.openFile(cwd!, match.path, match.lineNumber)) {
                host.status("Open a thread of this project to read the file.", "error");
              }
            },
          });
        }
      }
    }
    return list;
  };

  return {
    id: "projectSearch",
    commands: () =>
      options.workspace() === null
        ? []
        : [
            {
              id: "section.projectSearch",
              title: "Search project contents",
              keywords: "find grep text files search in project",
              action: "section.open",
              payload: { id: "projectSearch" },
            },
          ],
    open: () => {
      const workspace = options.workspace();
      // A search belongs to its project: another one starts empty.
      if (workspace?.cwd !== cwd) {
        query = "";
        result = null;
        error = null;
      }
      cwd = workspace?.cwd ?? null;
      label = workspace?.label ?? "";
      if (cwd !== null && query === "") ask();
    },
    close: () => {
      generation += 1;
      searching = false;
    },
    page: () => ({ title: label === "" ? "search" : `search · ${label}`, items: items() }),
  };
}
