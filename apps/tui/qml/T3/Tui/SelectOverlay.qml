import OpenTUI

// The one open picker from `Shell.state.select`: model, effort, access,
// workspace, branch, or an add-project step. ↑/↓, Enter and Esc come from
// the shell's keymap; rows are clickable; steps with a field take typing.
Rectangle {
    id: overlay
    objectName: "selectOverlay"
    readonly property var model: Shell.state.select
    readonly property string hostInput: model.input !== null ? model.input.text : ""
    onHostInputChanged: if (selectInput.text !== hostInput) selectInput.text = hostInput

    visible: model.open
    border.width: 1
    border.color: Theme.colors.accent
    title: " " + model.title + " "
    titleColor: Theme.colors.dim
    color: Theme.colors.bg
    flexDirection: "column"
    flexShrink: 0
    paddingX: 1

    TextInput {
        id: selectInput
        objectName: "selectInput"
        visible: overlay.model.input !== null
        height: 1
        focus: overlay.model.open && overlay.model.input !== null && Shell.state.mode === "select"
        placeholderText: overlay.model.input !== null ? overlay.model.input.placeholder : ""
        color: Theme.colors.text
        focusedColor: Theme.colors.text
        backgroundColor: Theme.colors.bg
        focusedBackgroundColor: Theme.colors.bg
        onTextEdited: Shell.dispatch("select.input.set", { text: text })
        onAccepted: Shell.dispatch("select.confirm")
    }

    Text {
        visible: overlay.model.input === null && overlay.model.status !== "ready"
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
