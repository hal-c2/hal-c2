import type { PaletteCommand } from "./paletteState.ts";

/**
 * Palette commands for the source-control panel, the diff viewer, checkpoint
 * revert and settings. The palette appends these to its list.
 */
export function detailCommands(input: {
  readonly panelOpen: boolean;
  /** The agents panel is open and shows (nothing hides it). */
  readonly agentsOpen: boolean;
  readonly hasCheckpoints: boolean;
}): PaletteCommand[] {
  return [
    ...(input.hasCheckpoints
      ? [
          { id: "diff", title: "View all changes", keywords: "diff", action: "diff.all" },
          {
            id: "revert",
            title: "Revert to checkpoint…",
            keywords: "undo checkpoint restore",
            action: "checkpoint.revert.open",
          },
        ]
      : []),
    {
      id: "panel",
      title: input.panelOpen ? "Hide source-control panel" : "Show source-control panel",
      hint: "^L",
      keywords: "git",
      action: "rightPanel.toggle",
    },
    {
      id: "agents",
      title: input.agentsOpen ? "Hide agents panel" : "Show agents panel",
      hint: "^X a",
      keywords: "workers subagents delegated tasks",
      // Hiding closes the panel; ^X a's toggle would focus a panel that shows without the keys.
      // Showing opens it with the keys, also when the file browser or a page hides it.
      action: input.agentsOpen ? "agents.close" : "agents.show",
    },
    {
      id: "settings",
      title: "Settings",
      keywords: "keybindings reference help providers",
      action: "settings.open",
    },
  ];
}
