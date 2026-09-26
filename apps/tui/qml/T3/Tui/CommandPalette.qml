import OpenTUI

// The command palette (`Shell.state.palette`): a query field over the ranked
// matches. Typing re-ranks (`palette.query`), Enter runs the selected command
// (`palette.run`), a click runs that one; the shell's keys move and close it.
Rectangle {
    id: palette
    objectName: "commandPalette"
    readonly property var state: Shell.state.palette
    readonly property string query: state.query
    onQueryChanged: if (queryInput.text !== query) queryInput.text = query

    visible: state.open
    height: Shell.state.layout.popoverRows
    flexShrink: 0
    border.width: 1
    border.color: Theme.colors.accent
    title: " Commands "
    titleColor: Theme.colors.dim
    color: Theme.colors.bg
    flexDirection: "column"
    paddingX: 1

    TextInput {
        id: queryInput
        objectName: "paletteQuery"
        height: 1
        focus: palette.state.open && Shell.state.mode === "command"
        placeholderText: "Type a command"
        color: Theme.colors.text
        focusedColor: Theme.colors.text
        backgroundColor: Theme.colors.bg
        focusedBackgroundColor: Theme.colors.bg
        onTextEdited: Shell.dispatch("palette.query", { query: text })
        onAccepted: Shell.dispatch("palette.run")
    }

    Repeater {
        model: palette.state.items
        delegate: Item {
            height: 1
            flexDirection: "row"
            onMouseDown: (mouse) => Shell.dispatch("palette.run", { id: modelData.id })
            Text {
                flexGrow: 1
                flexShrink: 1
                truncate: true
                text: (modelData.selected ? "▸ " : "  ") + modelData.title
                color: modelData.selected ? Theme.colors.accent : Theme.colors.text
            }
            Text {
                text: modelData.hint.length > 0 ? " " + modelData.hint : ""
                color: Theme.colors.faint
            }
        }
    }

    Text {
        visible: palette.state.items.length === 0
        text: "No matching commands"
        color: Theme.colors.faint
    }
}
