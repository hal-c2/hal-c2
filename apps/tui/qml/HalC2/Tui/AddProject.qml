import OpenTUI

// Adding a project, from `Shell.state.addProject` (AddProjectOverlay.tsx): a
// rounded accent box above the prompt with the field and its action, the
// step's title and keys, the repository being cloned, and the source or
// folder rows. Tab moves the keys between the field and the list.
Rectangle {
    id: panel
    objectName: "addProject"
    readonly property var flow: Shell.state.addProject
    // Typing breaks a `text` binding, so follow the host's query by hand
    // (choosing a folder or going back rewrites it there).
    readonly property string query: flow.query
    onQueryChanged: if (input.text !== query) input.text = query

    visible: flow.open
    border.width: 1
    border.style: "rounded"
    border.color: Theme.colors.accent
    color: Theme.colors.bg
    flexDirection: "column"
    flexShrink: 0
    paddingX: 1

    Row {
        height: 1
        Text {
            flexShrink: 0
            text: "＋ "
            color: Theme.colors.accent
        }
        TextInput {
            id: input
            objectName: "addProjectInput"
            visible: !panel.flow.listFocused
            flexGrow: 1
            height: 1
            focus: panel.flow.open && !panel.flow.listFocused && Shell.state.mode === "project"
            placeholderText: panel.flow.placeholder
            placeholderColor: Theme.colors.dim
            cursorColor: Theme.colors.accent
            color: Theme.colors.text
            focusedColor: Theme.colors.text
            backgroundColor: Theme.colors.bg
            focusedBackgroundColor: Theme.colors.bg
            onTextEdited: Shell.dispatch("project.add.input", { text: text })
            // A focused field keeps Enter from the shell's keys, so it acts itself.
            onAccepted: Shell.dispatch("project.add.activate")
        }
        Text {
            objectName: "addProjectField"
            visible: panel.flow.listFocused
            flexGrow: 1
            wrapMode: "none"
            text: panel.flow.field
            onMouseDown: Shell.dispatch("project.add.focusInput")
        }
        Text {
            objectName: "addProjectAction"
            flexShrink: 0
            wrapMode: "none"
            onMouseDown: Shell.dispatch("project.add.action")
            Span { text: "  "; color: Theme.colors.dim }
            Span { text: panel.flow.actionLabel; color: Theme.colors.accent }
        }
    }
    Text {
        objectName: "addProjectTitle"
        text: panel.flow.header
    }
    Item {
        visible: panel.flow.context !== null
        flexDirection: "column"
        paddingLeft: 2
        Text { text: "Repository"; color: Theme.colors.dim }
        Text { wrapMode: "none"; text: panel.flow.context ? panel.flow.context.title : "" }
        Text { wrapMode: "none"; text: panel.flow.context ? panel.flow.context.description : "" }
    }
    Text {
        objectName: "addProjectMessage"
        visible: panel.flow.messageLine !== null
        text: panel.flow.messageLine ?? ""
    }
    Repeater {
        model: panel.flow.rows
        delegate: Rectangle {
            flexDirection: "column"
            flexShrink: 0
            color: modelData.selected ? Theme.colors.selectedBg : Theme.colors.bg
            onMouseDown: if (!modelData.disabled) Shell.dispatch("project.add.select", { index: modelData.index })
            Text { height: 1; wrapMode: "none"; text: modelData.line }
            Text {
                visible: modelData.detail !== null
                height: 1
                wrapMode: "none"
                text: modelData.detail ?? ""
            }
        }
    }
}
