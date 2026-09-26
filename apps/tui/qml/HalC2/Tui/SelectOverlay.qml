import OpenTUI

// The one open picker from `Shell.state.select` (SelectOverlay.tsx): model,
// effort, access, workspace or branch, in a rounded accent box above the
// prompt. ↑/↓, Enter and Esc come from the shell's keymap; options are
// clickable. The host windows and paints the rows.
Rectangle {
    id: overlay
    objectName: "selectOverlay"
    readonly property var model: Shell.state.select

    visible: model.open
    border.width: 1
    border.style: "rounded"
    border.color: Theme.colors.accent
    color: Theme.colors.bg
    flexDirection: "column"
    flexShrink: 0
    paddingX: 1

    Text {
        Span { text: overlay.model.title + " ▸ "; color: Theme.colors.accent }
        Span { text: "↑/↓ or click · Enter apply · Esc cancel"; color: Theme.colors.dim }
    }

    Text {
        objectName: "selectStatus"
        visible: overlay.model.rows.length === 0
        text: overlay.model.status === "loading"
            ? "loading…"
            : overlay.model.status === "error" ? "failed to load" : "nothing to choose"
        color: overlay.model.status === "error" ? Theme.colors.error : Theme.colors.dim
    }

    Repeater {
        model: overlay.model.rows
        delegate: Rectangle {
            flexDirection: "column"
            flexShrink: 0
            color: modelData.active ? Theme.colors.selectedBg : Theme.colors.bg
            onMouseDown: Shell.dispatch("select.choose", { index: modelData.index })
            Text { height: 1; wrapMode: "none"; text: modelData.name }
            Text {
                visible: modelData.description !== null
                height: 1
                wrapMode: "none"
                text: modelData.description !== null ? modelData.description : ""
            }
        }
    }
}
