import OpenTUI

// The command palette (^K), like CommandPalette: a rounded accent box over
// the prompt, the "⌘" query field over the commands in view
// (`Shell.state.palette.rows`, a window around the highlighted one that the
// host styles), then the key hint. Typing filters (`palette.query.set`),
// Enter or a click runs a command, ↑/↓ and Esc come from the shell's keymap.
Rectangle {
    id: palette
    objectName: "commandPalette"
    readonly property var model: Shell.state.palette
    // Typing breaks a `text` binding; the host resets the query on open.
    readonly property string hostQuery: model.query
    onHostQueryChanged: if (queryInput.text !== hostQuery) queryInput.text = hostQuery

    visible: model.open
    border.width: 1
    border.style: "rounded"
    border.color: Theme.colors.accent
    color: Theme.colors.bg
    flexDirection: "column"
    flexShrink: 0
    paddingX: 1

    Item {
        flexDirection: "row"
        height: 1
        flexShrink: 0
        Text { flexShrink: 0; text: "⌘ "; color: Theme.colors.accent }
        TextInput {
            id: queryInput
            objectName: "paletteQuery"
            flexGrow: 1
            height: 1
            focus: palette.model.open && Shell.state.mode === "command"
            placeholderText: "Type a command…"
            placeholderColor: Theme.colors.dim
            cursorColor: Theme.colors.accent
            color: Theme.colors.text
            focusedColor: Theme.colors.text
            backgroundColor: Theme.colors.bg
            focusedBackgroundColor: Theme.colors.bg
            onTextEdited: Shell.dispatch("palette.query.set", { query: text })
            onAccepted: Shell.dispatch("palette.run")
        }
    }

    Text {
        visible: palette.model.commands.length === 0
        flexShrink: 0
        text: "no matching command"
        color: Theme.colors.dim
    }
    Repeater {
        model: palette.model.rows
        delegate: Rectangle {
            height: 1
            flexShrink: 0
            color: modelData.active ? Theme.colors.selectedBg : Theme.colors.bg
            onMouseDown: Shell.dispatch("palette.run", { index: modelData.index })
            Text { text: modelData.text }
        }
    }

    Text {
        flexShrink: 0
        text: "↑/↓ select · Enter run · Esc close"
        color: Theme.colors.dim
    }
}
