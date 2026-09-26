import OpenTUI

// The new-thread form (`Shell.state.newThread`): where the thread will work
// (a new worktree from a base branch, or the current workspace) and the
// project's branches. The first message is typed in the composer below;
// Enter starts the thread (`composer.submit`), Esc cancels (`composer.escape`).
Rectangle {
    id: form
    objectName: "newThreadForm"
    readonly property var draft: Shell.state.newThread
    readonly property bool newWorktree: draft !== null && draft.workspaceMode === "new-worktree"

    visible: draft !== null
    color: Theme.colors.bg
    flexDirection: "column"
    paddingX: 1

    Text {
        objectName: "newThreadTitle"
        text: form.draft ? "New thread · " + form.draft.projectName : ""
        color: Theme.colors.text
        font.bold: true
    }
    Item {
        flexDirection: "row"
        height: 1
        Text {
            objectName: "newThreadNewWorktree"
            text: (form.newWorktree ? "(•) " : "( ) ") + "New worktree"
            color: form.newWorktree ? Theme.colors.accent : Theme.colors.dim
            onMouseDown: (mouse) => Shell.dispatch("newThread.workspaceMode", { mode: "new-worktree" })
        }
        Text {
            objectName: "newThreadCurrent"
            text: "   " + (form.newWorktree ? "( ) " : "(•) ")
                + (form.draft && !form.newWorktree ? form.draft.workspaceLabel : "Current workspace")
            color: form.newWorktree ? Theme.colors.dim : Theme.colors.accent
            onMouseDown: (mouse) => Shell.dispatch("newThread.workspaceMode", { mode: "current" })
        }
    }
    Text {
        objectName: "newThreadBranch"
        text: form.draft
            ? (form.newWorktree ? "Base branch: " : "Branch: ") + (form.draft.branch ?? "none")
                + (!form.newWorktree && form.draft.worktreePath ? " · " + form.draft.worktreePath : "")
            : ""
        color: Theme.colors.dim
        truncate: true
    }
    Text {
        visible: form.draft !== null && form.draft.refsStatus !== "ready"
        text: form.draft === null ? ""
            : form.draft.refsStatus === "loading" ? "Loading branches…"
            : form.draft.refsStatus === "empty" ? "No branches" : "Could not list branches"
        color: Theme.colors.faint
    }
    Repeater {
        model: form.draft ? form.draft.refs : []
        delegate: Text {
            height: 1
            truncate: true
            text: (modelData.selected ? "▸ " : "  ") + modelData.name
                + (modelData.current ? " (checked out)" : "")
                + (modelData.worktreePath ? " (worktree)" : "")
            color: modelData.selected ? Theme.colors.accent : Theme.colors.text
            onMouseDown: (mouse) => Shell.dispatch("newThread.branch", { name: modelData.name })
        }
    }
}
