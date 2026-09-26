import OpenTUI

// With no projects yet and the add-project box closed, the conversation's
// place invites the user to add one (`Shell.state.addProject.invite`).
Item {
    objectName: "addProjectInvite"
    flexDirection: "column"
    paddingX: 1
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
