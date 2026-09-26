import OpenTUI

// Adding a project, from `Shell.state.addProject`: the source list, then a
// folder path (with the folders under it) or a repository to clone. With no
// projects yet and the flow closed, it is the invitation to add one instead.
Rectangle {
    id: panel
    objectName: "addProject"
    readonly property var flow: Shell.state.addProject
    // Typing breaks a `text` binding, so follow the host's query by hand
    // (choosing a folder or going back rewrites it there).
    readonly property string query: flow.query
    onQueryChanged: if (input.text !== query) input.text = query

    border.width: panel.flow.open ? 1 : 0
    border.color: Theme.colors.accent
    color: Theme.colors.bg
    flexDirection: "column"
    paddingX: 1

    Item {
        visible: !panel.flow.open
        flexDirection: "column"
        paddingY: 1
        Text {
            objectName: "addProjectInviteTitle"
            text: "What should we work on?"
            color: Theme.colors.text
            font.bold: true
        }
        Text {
            text: "Add a project to start your first thread."
            color: Theme.colors.dim
        }
        Text {
            objectName: "addProjectInviteAction"
            text: "[ Add project ]"
            color: Theme.colors.accent
            onMouseDown: Shell.dispatch("project.add")
        }
    }

    Row {
        visible: panel.flow.open
        height: 1
        Text {
            flexShrink: 0
            text: "＋ "
            color: Theme.colors.accent
        }
        TextInput {
            id: input
            objectName: "addProjectInput"
            flexGrow: 1
            height: 1
            focus: panel.flow.open && Shell.state.mode === "project"
            placeholderText: panel.flow.placeholder
            color: Theme.colors.text
            focusedColor: Theme.colors.text
            backgroundColor: Theme.colors.bg
            focusedBackgroundColor: Theme.colors.bg
            onTextEdited: Shell.dispatch("project.add.input", { text: text })
            onAccepted: Shell.dispatch("project.add.activate")
        }
    }
    Row {
        visible: panel.flow.open
        height: 1
        Text {
            objectName: "addProjectTitle"
            flexShrink: 0
            text: panel.flow.title + " ▸ "
            color: Theme.colors.accent
        }
        Text {
            flexShrink: 1
            truncate: true
            wrapMode: "none"
            text: panel.flow.pending ? "working…" : panel.flow.hint
            color: Theme.colors.dim
        }
    }
    Item {
        visible: panel.flow.open && panel.flow.repository !== null
        flexDirection: "column"
        paddingLeft: 2
        Text { text: "Repository"; color: Theme.colors.dim }
        Text {
            text: panel.flow.repository ? panel.flow.repository.title : ""
            color: Theme.colors.text
            truncate: true
            wrapMode: "none"
        }
        Text {
            text: panel.flow.repository ? panel.flow.repository.description : ""
            color: Theme.colors.dim
            truncate: true
            wrapMode: "none"
        }
    }
    Text {
        objectName: "addProjectMessage"
        visible: panel.flow.open && panel.flow.rows.length === 0 && panel.flow.message !== ""
        text: panel.flow.message
        color: panel.flow.status === "error" ? Theme.colors.error : Theme.colors.dim
    }
    Repeater {
        model: panel.flow.open ? panel.flow.rows : []
        delegate: Row {
            height: 1
            onMouseDown: Shell.dispatch("project.add.select", { index: modelData.index })
            Text {
                flexShrink: 0
                text: (modelData.selected ? "▸ " : "  ") + modelData.title
                    + (modelData.disabled ? " · needs setup" : "")
                color: modelData.disabled
                    ? Theme.colors.faint
                    : modelData.selected ? Theme.colors.text : Theme.colors.dim
                font.bold: modelData.selected
            }
            Text {
                flexShrink: 1
                truncate: true
                wrapMode: "none"
                text: modelData.description !== "" ? "  " + modelData.description : ""
                color: Theme.colors.faint
            }
        }
    }
}
