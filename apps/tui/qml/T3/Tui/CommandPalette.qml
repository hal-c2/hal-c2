import OpenTUI

// The command palette (^K): a search field over `Shell.state.palette`.
// Typing filters (`palette.query.set`), Enter runs the highlighted command,
// ↑/↓ and Esc come from the shell's keymap.
Rectangle {
    id: palette
    objectName: "commandPalette"
    readonly property var model: Shell.state.palette
    // Typing breaks a `text` binding; the host resets the query on open.
    readonly property string hostQuery: model.query
    onHostQueryChanged: if (queryInput.text !== hostQuery) queryInput.text = hostQuery

    visible: model.open
    border.width: 1
    border.color: Theme.colors.accent
    title: " Commands "
    titleColor: Theme.colors.dim
    color: Theme.colors.bg
    flexDirection: "column"
    flexShrink: 0
    paddingX: 1

    TextInput {
        id: queryInput
        objectName: "paletteQuery"
        height: 1
        focus: palette.model.open && Shell.state.mode === "command"
        placeholderText: "Type a command…"
        color: Theme.colors.text
        focusedColor: Theme.colors.text
        backgroundColor: Theme.colors.bg
        focusedBackgroundColor: Theme.colors.bg
        onTextEdited: Shell.dispatch("palette.query.set", { query: text })
        onAccepted: Shell.dispatch("palette.run")
    }

    Repeater {
        model: palette.model.commands
        delegate: Item {
            flexDirection: "row"
            height: 1
            Text {
                flexGrow: 1
                text: (index === palette.model.index ? "▸ " : "  ") + modelData.title
                color: index === palette.model.index ? Theme.colors.accent : Theme.colors.text
                onMouseDown: Shell.dispatch("palette.run", { index: index })
            }
            Text { text: modelData.hint; color: Theme.colors.faint }
        }
    }

    Text {
        visible: palette.model.commands.length === 0
        text: "No matching commands"
        color: Theme.colors.faint
    }
}
