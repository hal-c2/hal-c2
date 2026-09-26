import OpenTUI

// The built-in arrangement. A user shell.qml can use it as its root and tweak
// one piece (`DefaultShell { sidebar.width: 40 }`) or compose the bricks anew.
//
// Keys are mode-scoped Shortcuts for now; the full keymap replaces them.
ShellWindow {
    id: shell
    property alias conversation: conversationView

    Conversation {
        id: conversationView
        flexGrow: 1
        visible: !Shell.state.files.open && !Shell.state.addProject.open && !Shell.state.addProject.invite
    }

    // Pending the palette: adding a project (and, with none yet, the
    // invitation to) takes the conversation's place.
    Loader {
        objectName: "addProjectLoader"
        active: Shell.state.addProject.open || Shell.state.addProject.invite
        sourceComponent: AddProject { flexGrow: 1 }
    }

    // Pending the layout's right panel slot: the file browser and an opened
    // file take the conversation's place.
    Loader {
        objectName: "filesPanelLoader"
        active: Shell.state.files.open && Shell.state.files.viewer === null
        sourceComponent: FilesPanel { flexGrow: 1 }
    }
    Loader {
        objectName: "fileViewerLoader"
        active: Shell.state.files.open && Shell.state.files.viewer !== null
        sourceComponent: FileViewer { flexGrow: 1 }
    }

    // Pending the layout's drawer slot: the terminal sits under the conversation.
    Loader {
        id: terminalDrawerLoader
        objectName: "terminalDrawerLoader"
        active: Shell.state.terminal.open
        sourceComponent: TerminalDrawer {}
    }

    Shortcut {
        sequence: "ctrl+f"
        enabled: Shell.state.mode === "compose"
        onActivated: Shell.dispatch("sidebar.filter.focus")
    }
    Shortcut {
        sequence: "escape"
        enabled: Shell.state.mode === "filter"
        onActivated: Shell.dispatch("sidebar.filter.cancel")
    }
    // Terminal drawer. Focused, every other key goes to the running program.
    Shortcut {
        sequence: "ctrl+e"
        enabled: Shell.state.mode === "compose" || Shell.state.mode === "terminal"
        onActivated: Shell.dispatch("terminal.toggle")
    }
    Shortcut {
        sequence: "ctrl+p"
        enabled: Shell.state.terminal.open && (Shell.state.mode === "compose" || Shell.state.mode === "terminal")
        onActivated: Shell.dispatch("terminal.focus.toggle")
    }
    Shortcut {
        sequence: "ctrl+o"
        enabled: Shell.state.mode === "terminal"
        onActivated: Shell.dispatch("terminal.copy")
    }
    Shortcut {
        sequence: "shift+pageup"
        enabled: Shell.state.mode === "terminal"
        onActivated: Shell.dispatch("terminal.scroll", { action: "page-up" })
    }
    Shortcut {
        sequence: "shift+pagedown"
        enabled: Shell.state.mode === "terminal"
        onActivated: Shell.dispatch("terminal.scroll", { action: "page-down" })
    }
    Shortcut {
        sequence: "shift+up"
        enabled: Shell.state.mode === "terminal"
        onActivated: Shell.dispatch("terminal.scroll", { action: "line-up" })
    }
    Shortcut {
        sequence: "shift+down"
        enabled: Shell.state.mode === "terminal"
        onActivated: Shell.dispatch("terminal.scroll", { action: "line-down" })
    }
    Shortcut {
        sequence: "ctrl+up"
        enabled: Shell.state.mode === "terminal"
        onActivated: Shell.dispatch("terminal.resize", { delta: 2 })
    }
    Shortcut {
        sequence: "ctrl+down"
        enabled: Shell.state.mode === "terminal"
        onActivated: Shell.dispatch("terminal.resize", { delta: -2 })
    }
    // File browser and viewer.
    Shortcut {
        sequence: "up"
        enabled: Shell.state.mode === "files"
        onActivated: Shell.dispatch("files.move", { delta: -1 })
    }
    Shortcut {
        sequence: "down"
        enabled: Shell.state.mode === "files"
        onActivated: Shell.dispatch("files.move", { delta: 1 })
    }
    Shortcut {
        sequence: "pageup"
        enabled: Shell.state.mode === "files"
        onActivated: Shell.dispatch("files.page", { delta: -1 })
    }
    Shortcut {
        sequence: "pagedown"
        enabled: Shell.state.mode === "files"
        onActivated: Shell.dispatch("files.page", { delta: 1 })
    }
    Shortcut {
        sequence: "return, right"
        enabled: Shell.state.mode === "files"
        onActivated: Shell.dispatch("files.activate")
    }
    Shortcut {
        sequence: "left, backspace"
        enabled: Shell.state.mode === "files"
        onActivated: Shell.dispatch("files.up")
    }
    Shortcut {
        sequence: "escape"
        enabled: Shell.state.mode === "files"
        onActivated: Shell.dispatch("files.back")
    }
    // Adding a project: the path field keeps the typing, these move and leave.
    Shortcut {
        sequence: "up"
        enabled: Shell.state.mode === "project"
        onActivated: Shell.dispatch("project.add.move", { delta: -1 })
    }
    Shortcut {
        sequence: "down"
        enabled: Shell.state.mode === "project"
        onActivated: Shell.dispatch("project.add.move", { delta: 1 })
    }
    Shortcut {
        sequence: "escape"
        enabled: Shell.state.mode === "project"
        onActivated: Shell.dispatch("project.add.back")
    }
    // The renderer does not exit on Ctrl+C; the app tears down in order. In the
    // terminal it interrupts the running program instead.
    Shortcut {
        sequence: "ctrl+c"
        enabled: Shell.state.mode !== "terminal"
        onActivated: Shell.dispatch("app.quit")
    }
}
