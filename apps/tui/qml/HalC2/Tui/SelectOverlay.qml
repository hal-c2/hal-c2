import OpenTUI

// The one open picker from `Shell.state.select` (SelectOverlay.tsx): model,
// effort, access, workspace or branch, or a list another area opened, in a
// rounded accent box above the prompt. ↑/↓, Enter and Esc come from the
// shell's keymap; options are clickable. The host windows and paints the rows.
// A searchable list has a field under its title; typing narrows the options
// (`select.query.set`).
Rectangle {
    id: overlay
    objectName: "selectOverlay"
    readonly property var model: Shell.state.select
    // A new list starts with an empty field (typing breaks a `text` binding).
    readonly property string listTitle: model.title
    onListTitleChanged: search.text = ""

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

    Item {
        visible: overlay.model.searchable
        flexDirection: "row"
        height: 1
        flexShrink: 0
        Text { flexShrink: 0; text: "⌕ "; color: Theme.colors.accent }
        TextInput {
            id: search
            objectName: "selectSearch"
            flexGrow: 1
            height: 1
            focus: overlay.model.open && overlay.model.searchable
            placeholderText: "Type to search…"
            placeholderColor: Theme.colors.dim
            cursorColor: Theme.colors.accent
            color: Theme.colors.text
            focusedColor: Theme.colors.text
            backgroundColor: Theme.colors.bg
            focusedBackgroundColor: Theme.colors.bg
            onTextEdited: Shell.dispatch("select.query.set", { query: text })
            // A focused field keeps Enter from the shell's keys, so it applies itself.
            onAccepted: Shell.dispatch("select.confirm")
        }
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
