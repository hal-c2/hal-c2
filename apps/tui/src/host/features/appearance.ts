import { usesNerdFont } from "../../icons.ts";
import { COLOUR_THEME_CHOICES, currentColourTheme } from "../../theme.ts";
import type { Feature, FeatureKit } from "./kit.ts";

/**
 * How the client looks: its colour theme (the terminal's own by default) and
 * whether its icons are Nerd Fonts glyphs. The host owns the switch and the
 * repaint (`theme.set`, `icons.nerdFont.set`); this offers them.
 */
export function createAppearanceFeature(kit: FeatureKit): Feature {
  const pickTheme = () => {
    // NO_COLOR is not a theme to leave: the environment asked for it.
    if (currentColourTheme() === "none") {
      kit.status("NO_COLOR is set: the client draws without colour.", "info");
      return;
    }
    kit.menu({
      title: "colour theme",
      options: COLOUR_THEME_CHOICES.map((choice) => ({
        label: choice.label,
        description:
          choice.id === "terminal"
            ? "Borrow the terminal's own colours."
            : "The client's own colours, whatever the terminal's palette.",
        value: choice.id,
      })),
      index: Math.max(
        0,
        COLOUR_THEME_CHOICES.findIndex((choice) => choice.id === currentColourTheme()),
      ),
      onChoose: (id) => {
        kit.dispatch("theme.set", { id });
        const label = COLOUR_THEME_CHOICES.find((choice) => choice.id === id)?.label ?? id;
        kit.status(`Theme → ${label}`, "success");
      },
    });
  };

  return {
    commands: () => [
      {
        id: "theme.pick",
        title: "Change colour theme…",
        keywords: "appearance colors palette dark",
        action: "theme.pick",
      },
      usesNerdFont()
        ? {
            id: "icons.plain",
            title: "Use plain icons",
            keywords: "nerd font glyphs",
            action: "icons.nerdFont.set",
            payload: { on: false },
          }
        : {
            id: "icons.nerd",
            title: "Use nerd font icons",
            keywords: "glyphs icons font",
            action: "icons.nerdFont.set",
            payload: { on: true },
          },
    ],
    dispatch: (action) => {
      if (action !== "theme.pick") return false;
      pickTheme();
      return true;
    },
  };
}
