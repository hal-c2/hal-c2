import { clip } from "../../format.ts";
import { plainText, type StyledText } from "../styledText.ts";
import type { Feature, FeatureKit } from "./kit.ts";

interface Actionable {
  readonly text?: StyledText | string;
  readonly action?: string | null;
  readonly payload?: unknown;
}
interface TimelineLine extends Actionable {
  readonly right?: Actionable | null;
  readonly parts?: ReadonlyArray<Actionable>;
}

const textOf = (value: StyledText | string | undefined): string =>
  value === undefined ? "" : typeof value === "string" ? value : plainText(value);

/**
 * What the mouse does, from the keyboard. Some things are only clicked: a
 * timeline line (a fold, a changed file, an image, a link), a notification's
 * buttons, a shelf's header, the thread menu, the project row. Each has a
 * palette entry here, so the client works with the mouse turned off
 * (`HAL_C2_TUI_MOUSE=0`) and in a terminal that reports no mouse at all.
 */
export function createReachFeature(kit: FeatureKit): Feature {
  /** Every clickable line of the conversation, newest last, as (what it reads, what a click does). */
  const timelineActions = () => {
    const timeline = kit.state.get("timeline") as
      | { items?: ReadonlyArray<{ lines?: ReadonlyArray<TimelineLine> }> }
      | undefined;
    const found: Array<{ label: string; action: string; payload: unknown }> = [];
    const add = (entry: Actionable | null | undefined, fallback: string) => {
      if (!entry || typeof entry.action !== "string" || entry.action === "") return;
      const label = textOf(entry.text).trim() || fallback;
      found.push({ label: clip(label, 120), action: entry.action, payload: entry.payload });
    };
    for (const item of timeline?.items ?? []) {
      for (const line of item.lines ?? []) {
        const text = textOf(line.text).trim();
        add(line, text);
        for (const part of line.parts ?? []) add(part, text);
        add(line.right, text);
      }
    }
    return found;
  };

  const notifications = () =>
    (
      kit.state.get("notifications") as
        | {
            items?: ReadonlyArray<{
              id: string;
              title: string;
              description?: string;
              actions?: ReadonlyArray<{ id: string; label: string }>;
            }>;
          }
        | undefined
    )?.items ?? [];

  const shelves = () =>
    (
      (
        kit.state.get("sidebar") as
          | {
              rows?: ReadonlyArray<{
                kind: string;
                section?: string;
                title?: string;
                expanded?: boolean;
              }>;
            }
          | undefined
      )?.rows ?? []
    ).filter((row) => row.kind === "section" || row.kind === "more");

  const pickTimelineAction = () => {
    const actions = timelineActions();
    if (actions.length === 0) {
      kit.status("Nothing in the conversation can be opened or folded.", "info");
      return;
    }
    kit.menu({
      title: "conversation",
      searchable: true,
      options: actions.map((entry, index) => ({
        label: entry.label,
        description: entry.action,
        value: String(index),
      })),
      // The newest line is the likeliest target.
      index: actions.length - 1,
      onChoose: (value) => {
        const entry = actions[Number(value)];
        if (entry) kit.dispatch(entry.action, entry.payload);
      },
    });
  };

  const pickNotification = () => {
    const options = notifications().flatMap((note) => {
      const about = note.description ? `${note.title} · ${note.description}` : note.title;
      return [
        ...(note.actions ?? []).map((action) => ({
          label: `${action.label}: ${about}`,
          value: JSON.stringify({
            action: "notification.action",
            payload: { id: note.id, actionId: action.id },
          }),
        })),
        {
          label: `Dismiss: ${about}`,
          value: JSON.stringify({ action: "notification.dismiss", payload: { id: note.id } }),
        },
      ];
    });
    if (options.length === 0) {
      kit.status("No notifications.", "info");
      return;
    }
    kit.menu({
      title: "notifications",
      options,
      onChoose: (value) => {
        const picked = JSON.parse(value) as { action: string; payload: unknown };
        kit.dispatch(picked.action, picked.payload);
      },
    });
  };

  /** The open thread's menu, where a right-click would put it: at the top of the list. */
  const openThreadMenu = () => {
    const key = (kit.state.get("sidebar") as { activeThreadKey?: string | null } | undefined)
      ?.activeThreadKey;
    if (key) kit.dispatch("thread.menu", { key, x: 2, y: 4 });
    else kit.status("Select a thread first.", "info");
  };

  return {
    commands: () => [
      ...(timelineActions().length > 0
        ? [
            {
              id: "reach.timeline",
              title: "Conversation actions…",
              keywords: "expand collapse fold open image link file changes click",
              action: "reach.timeline",
            },
          ]
        : []),
      ...(notifications().length > 0
        ? [
            {
              id: "reach.notifications",
              title: "Notifications…",
              keywords: "alerts dismiss open thread",
              action: "reach.notifications",
            },
          ]
        : []),
      ...shelves().map((row) =>
        row.kind === "more"
          ? {
              id: "reach.more",
              title: "Show more settled threads",
              keywords: "shelf list",
              action: "sidebar.more",
            }
          : {
              id: `reach.shelf.${row.section}`,
              title: `${row.expanded ? "Collapse" : "Expand"} the ${String(row.title).toLowerCase()} shelf`,
              keywords: "threads list section",
              action: "sidebar.section.toggle",
              payload: { section: row.section },
            },
      ),
      {
        id: "reach.scope",
        title: "Choose which project's threads to list…",
        keywords: "scope filter project row",
        action: "sidebar.scopePicker.toggle",
      },
      {
        id: "reach.threadMenu",
        title: "Thread menu…",
        keywords: "context menu copy path branch",
        action: "reach.threadMenu",
      },
      ...(((kit.state.get("composer") as { contexts?: ReadonlyArray<unknown> } | undefined)
        ?.contexts?.length ?? 0) > 0
        ? [
            {
              id: "reach.context.remove",
              title: "Remove last context chip",
              keywords: "terminal diff note",
              action: "composer.context.remove",
            },
          ]
        : []),
    ],
    dispatch: (action) => {
      switch (action) {
        case "reach.timeline":
          pickTimelineAction();
          return true;
        case "reach.notifications":
          pickNotification();
          return true;
        case "reach.threadMenu":
          openThreadMenu();
          return true;
        default:
          return false;
      }
    },
  };
}
