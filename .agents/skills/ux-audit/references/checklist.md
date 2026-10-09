# Desktop audit checklist

What exists in `apps/desktop-qt` and what "click everything" means. The
bricks are in `apps/desktop-qt/qml/HalC2/Bricks/`. The ledger is the full
list: every `features/**/*.feature` scenario tagged `@desktop` or `@shared`
is behaviour the desktop claims. `features/desktop/` and
`features/navigation/` are desktop-heavy. Grep the ledger for an area before
you audit it, so you know what it should do and what is `@backlog-desktop`.

## Window sizes and appearances

| Dimension   | Values                                                                                                                                      |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Window size | 1600x1000 (the sandbox's whole display), 1280x800, 960x1000 (half of a tiled 1920 screen, a common real size), 640x400 (the window minimum) |
| Panels      | at each size: sidebar open and collapsed, right panel closed and open                                                                       |
| Appearance  | light and dark (Settings › Appearance › Color scheme), plus one custom `theme.json` (examples in `apps/desktop-qt/examples/`)               |

`ux size <w> <h>` floats the window in the sandbox's sway and resizes it
(`set_window_frame` does not stick under sway). Shoot again after it, and
expect the first click after floating to be swallowed.

A custom theme goes in the app's shell config dir inside the sandbox
(`$HAL_C2_CUA_HOME/app/config/shell/theme.json`, default
`.hal-c2/cua/app/config/shell/theme.json`). It applies live. Never write
to `~/.config/hal-c2*`, even though the examples' README says to copy
themes there.

## Areas

Each area name is the prefix of its `coverage.jsonl` rows. The report
builder flags an area with no row.

| Area                        | Bricks (start here)                                                                                               | Exercise                                                                                                                                                                                                      |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Shell and header            | `DefaultLayout`, `Workspace`, `ShellWindow`, `TitleBar`, `GitActions`                                             | top tabs, breadcrumb with long project and thread names, the header pills and split buttons, window controls on every route and size, collapse and expand the sidebar and right panel, drag and resize        |
| Sidebar                     | `Sidebar`, `ThreadRow*`, `ArchivedThreads`, `ProjectIcon`                                                         | projects and threads with real data, long titles, status badges, pin, snooze and unsnooze, archive and restore, rename, context menus, search, new thread, multi-environment rows                             |
| Home and centre             | `HomePage`, `CentreHost`, `PullRequestsPage`, `PluginPages`                                                       | the landing page, the reviews and pull requests view, every centre route                                                                                                                                      |
| Timeline                    | `Timeline*`, `Markdown`, `AttachmentViewer`, `BackgroundActivityRow`                                              | a thread from every `ux census` group (`Timeline › <group>`): long threads (scroll performance), messages sent by tools and other agents, subagents, tool calls, diffs, plans, approvals, errors, attachments |
| Live turn                   | `Composer`, `Timeline*`, `ThreadRow*`                                                                             | in the scratch project: the working state in the timeline, sidebar and header; queue, edit, steer and cancel messages; interrupt; the finished turn and its diff                                              |
| Composer                    | `Composer`, `ModelPicker`, `ComposerAttachment`, `ComposerUsageLimits`                                            | every control in the bar for each provider, attachments, context references, keyboard sending and newline, drafts kept per thread                                                                             |
| Right panel › Diff          | `DiffPanel`                                                                                                       | threads in the main checkout, on a worktree, with a worktree outside the project's root, with no turns, in the scratch project after a turn                                                                   |
| Right panel › Files         | `FilesPanel`                                                                                                      | browse, open a long file, search, at narrow widths                                                                                                                                                            |
| Right panel › Agents        | `AgentsPanel`                                                                                                     | threads with and without subagents                                                                                                                                                                            |
| Right panel › Previews      | `PreviewsPanel`                                                                                                   | empty and with tabs                                                                                                                                                                                           |
| Right panel › Device        | `DevicePanel`                                                                                                     | empty and with a device, if one is available                                                                                                                                                                  |
| Right panel › Pull requests | `PullRequestsPanel`, `PullRequestReviewPanel`                                                                     | threads with and without pull requests; add and close tabs, maximise, narrow widths                                                                                                                           |
| Terminal                    | `TerminalDrawer`                                                                                                  | open, tabs, restart, resize                                                                                                                                                                                   |
| Command palette             | `CommandPalette`                                                                                                  | every command group, search, keyboard only, and that each action reachable elsewhere is here too                                                                                                              |
| Settings                    | `SettingsHost`, `SettingsNav`, every `*Settings.qml`                                                              | every page, every control saved and confirmed after an app relaunch, scopes and inheritance, the theme editor, keybindings, providers, connections and pairing, plugins, scheduled tasks, diagnostics         |
| Dialogs and toasts          | `ConfirmDialog`, `RevertDialog`, `EditFromHereDialog`, `ProjectRemovalDialog`, `Notifications`, `ContextMenuHost` | consequence stated, focus taken and returned, Escape closes, toasts readable, dismissable and not covering controls                                                                                           |
| Connection and errors       | `ConnectionNotice`, `ConnectionStatusRow`, `ShellErrorOverlay`                                                    | `ux mc-stop`, watch the app degrade (every notice, and what still looks usable), `ux mc-start`, watch it recover and whether any warning lingers                                                              |
| Keyboard                    | `KeybindingController` (C++), `KeybindingsSettings`                                                               | see below                                                                                                                                                                                                     |

## Keyboard

For each area: the Tab order, a visible focus ring, Escape and Enter in
dialogs and menus, and the keybindings listed in Settings › Keybindings. Do
those keybindings do what their labels say?

## Known-good patterns

An audit judged these fine. Re-verify them, and report them only if they
broke.

- Settings persist across an app relaunch, and the last route comes back.
- Every keybinding in Settings › Keybindings does what its label says.
- The app recovers from a dropped MC without re-pairing, within seconds of
  the port reopening, with the timeline and sidebar intact.
- A custom `theme.json` applies live and reverts when removed.
- The palette works keyboard-only, searches thread content, and Escape
  steps back out of a mode before closing.
- Settings and the thread context menu adapt at 640x400.
- Snooze and wake, settle with Undo, inline rename and archive.
- Markdown tables, and older history paging in on scroll in long threads.
- The model picker's provider rail, search, favourites and accessible
  names, and the slash menu.
- The Device and Previews tabs explain their empty states.
- Focus rings in Settings, and Tab reaching the thread list.
