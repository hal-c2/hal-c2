import OpenTUI

// The one open picker from `Shell.state.select`: model, effort, access,
// workspace or branch. ↑/↓, Enter and Esc come from the shell's keymap; rows
// are clickable.
Rectangle {
    id: overlay
    objectName: "selectOverlay"
    readonly property var model: Shell.state.select

    visible: model.open
    border.width: 1
    border.color: Theme.colors.accent
    title: " " + model.title + " "
    titleColor: Theme.colors.dim
    color: Theme.colors.bg
    flexDirection: "column"
    flexShrink: 0
    paddingX: 1

    Text {
        visible: overlay.model.status !== "ready"
        text: overlay.model.status === "loading"
            ? "Loading…"
            : overlay.model.status === "error" ? "Could not load the options." : "Nothing to choose from."
        color: Theme.colors.faint
    }

    Repeater {
        model: overlay.model.options
        delegate: Item {
            flexDirection: "row"
            height: 1
            Text {
                flexShrink: 0
                wrapMode: "none"
                text: (index === overlay.model.index ? "▸ " : "  ") + modelData.label
                color: index === overlay.model.index ? Theme.colors.accent : Theme.colors.text
                onMouseDown: Shell.dispatch("select.choose", { index: index })
            }
            Text {
                flexShrink: 1
                wrapMode: "none"
                truncate: true
                text: "  " + modelData.description
                color: Theme.colors.faint
            }
        }
    }
}
