import { relativeTime } from "../../theme.ts";
import type { Feature, FeatureKit } from "./kit.ts";

const SORT = "__sort";
type Order = "newest" | "oldest";

/**
 * The archive: archived threads leave the thread list, so this lists them in
 * a searchable picker, newest first (or oldest). Choosing one opens it, where
 * the palette's "Unarchive thread" and "Delete thread" apply to it.
 */
export function createArchiveFeature(kit: FeatureKit): Feature {
  const open = (order: Order) => {
    const shell = kit.store.getState().shell;
    const projectTitle = (id: string) =>
      shell?.projects.find((project) => project.id === id)?.title ?? id;
    const archived = (shell?.threads ?? [])
      .filter((thread) => thread.archivedAt != null)
      .toSorted((left, right) => {
        const delta = Date.parse(right.archivedAt!) - Date.parse(left.archivedAt!);
        return order === "newest" ? delta : -delta;
      });
    if (archived.length === 0) {
      kit.status("No archived threads.", "info");
      return;
    }
    kit.menu({
      title: "archive",
      searchable: true,
      options: [
        {
          label: `Sort: ${order === "newest" ? "newest first" : "oldest first"}`,
          description: `Enter shows the ${order === "newest" ? "oldest" : "newest"} first.`,
          value: SORT,
        },
        ...archived.map((thread) => ({
          label: thread.title,
          description: `${projectTitle(thread.projectId)} · archived ${relativeTime(thread.archivedAt!, kit.nowMs())}`,
          value: thread.id as string,
        })),
      ],
      // Open on the first thread, not the sort row.
      index: 1,
      onChoose: (value) => {
        if (value === SORT) {
          open(order === "newest" ? "oldest" : "newest");
          return;
        }
        kit.store.select({ kind: "thread", id: value });
        kit.status("Archived thread open · ^K to unarchive or delete it.", "info");
      },
    });
  };
  return {
    commands: () => [
      {
        id: "archive.open",
        title: "Archived threads",
        keywords: "archive unarchive restore old",
        action: "archive.open",
      },
    ],
    dispatch: (action) => {
      if (action !== "archive.open") return false;
      open("newest");
      return true;
    },
  };
}
