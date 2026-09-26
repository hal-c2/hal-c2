import type { Command } from "../commands.ts";

/**
 * Palette commands for the source-control panel, the diff viewer, checkpoint
 * revert and settings. The palette appends these to its list; each one only
 * dispatches.
 */
export function detailCommands(input: {
  readonly panelOpen: boolean;
  readonly hasCheckpoints: boolean;
  readonly dispatch: (action: string, payload?: unknown) => void;
}): Command[] {
  const { dispatch } = input;
  return [
    ...(input.hasCheckpoints
      ? [
          {
            id: "diff",
            title: "View all changes",
            keywords: "diff",
            run: () => dispatch("diff.all"),
          },
          {
            id: "revert",
            title: "Revert to checkpoint…",
            keywords: "undo checkpoint restore",
            run: () => dispatch("checkpoint.revert.open"),
          },
        ]
      : []),
    {
      id: "panel",
      title: input.panelOpen ? "Hide source-control panel" : "Show source-control panel",
      hint: "^L",
      keywords: "git",
      run: () => dispatch("rightPanel.toggle"),
    },
    {
      id: "settings",
      title: "Settings",
      keywords: "keybindings reference help providers",
      run: () => dispatch("settings.open"),
    },
  ];
}
