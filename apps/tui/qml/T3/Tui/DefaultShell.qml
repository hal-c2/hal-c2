import OpenTUI

// The built-in arrangement. A user shell.qml can use it as its root and tweak
// one piece (`DefaultShell { sidebar.width: 40 }`) or compose the bricks anew.
//
// Keys are mode-scoped Shortcuts for now; the full keymap replaces them.
ShellWindow {
    id: shell
    property alias conversation: conversationView
    readonly property string mode: Shell.state.mode

    // The detail panel fills `layout.rightPanel` by its kind: source control,
    // or the file browser (an opened file in its place).
    rightPanelComponent: Shell.state.layout.rightPanel.kind === "sourceControl"
        ? sourceControlPanel
        : Shell.state.layout.rightPanel.kind === "files"
            ? (Shell.state.files.viewer === null ? filesPanel : fileViewer)
            : null
    Component {
        id: sourceControlPanel
        RightPanel {
            flexGrow: 1
            width: Shell.state.layout.rightPanel.asMain
                ? Shell.state.layout.mainWidth
                : Shell.state.layout.rightPanel.width
        }
    }
    Component {
        id: filesPanel
        FilesPanel {
            flexGrow: 1
            width: Shell.state.layout.rightPanel.asMain
                ? Shell.state.layout.mainWidth
                : Shell.state.layout.rightPanel.width
        }
    }
    Component {
        id: fileViewer
        FileViewer {
            flexGrow: 1
            width: Shell.state.layout.rightPanel.asMain
                ? Shell.state.layout.mainWidth
                : Shell.state.layout.rightPanel.width
        }
    }
    // The thread's terminal fills `layout.drawer` under the conversation.
    drawerComponent: terminalDrawer
    Component {
        id: terminalDrawer
        TerminalDrawer { flexGrow: 1 }
    }

    // Adding a project (and, with none yet, the invitation to) is a page in
    // the conversation's place.
    readonly property bool addingProject: Shell.state.addProject.open || Shell.state.addProject.invite

    // The conversation, or the settings page in its place.
    Conversation {
        id: conversationView
        visible: Shell.state.page.kind !== "draft" && !Shell.state.settings.active && !shell.addingProject
        flexGrow: 1
        flexShrink: 1
    }
    Loader {
        id: settingsLoader
        active: Shell.state.settings.active
        SettingsPage { flexGrow: 1 }
    }
    Loader {
        objectName: "addProjectLoader"
        active: shell.addingProject
        sourceComponent: AddProject { flexGrow: 1 }
    }
    NewThreadForm {
        flexGrow: 1
        flexShrink: 1
        visible: draft !== null && !shell.addingProject
    }
    CommandPalette {}
    ThreadOverlay {
        height: Shell.state.layout.composerRows
    }
    PromptBox {
        visible: Shell.state.overlay === null
            && Shell.state.page.kind !== "draft"
            && !Shell.state.settings.active
            && !shell.addingProject
    }

    Shortcut {
        sequence: "ctrl+f"
        enabled: shell.mode === "compose" || shell.mode === "newThread"
        onActivated: Shell.dispatch("sidebar.filter.focus")
    }
    Shortcut {
        sequence: "escape"
        enabled: shell.mode === "filter"
        onActivated: Shell.dispatch("sidebar.filter.cancel")
    }
    Shortcut {
        sequence: "ctrl+k"
        enabled: shell.mode === "compose" || shell.mode === "newThread"
        onActivated: Shell.dispatch("palette.open")
    }
    Shortcut {
        sequence: "ctrl+n"
        enabled: shell.mode === "compose"
        onActivated: Shell.dispatch("thread.new")
    }
    Shortcut {
        sequence: "ctrl+l"
        enabled: shell.mode === "compose" || shell.mode === "panel"
        onActivated: Shell.dispatch("rightPanel.toggle", { kind: "sourceControl" })
    }
    Shortcut {
        sequence: "ctrl+e"
        enabled: shell.mode === "compose" || shell.mode === "terminal"
        onActivated: Shell.dispatch("terminal.toggle")
    }

    // Thread list walking and jumping (Alt+1..9 counts visible threads).
    Shortcut { sequence: "alt+down"; enabled: shell.mode === "compose"; onActivated: Shell.dispatch("thread.next") }
    Shortcut { sequence: "alt+up"; enabled: shell.mode === "compose"; onActivated: Shell.dispatch("thread.previous") }
    Shortcut { sequence: "alt+1"; enabled: shell.mode === "compose"; onActivated: Shell.dispatch("thread.jump", { index: 1 }) }
    Shortcut { sequence: "alt+2"; enabled: shell.mode === "compose"; onActivated: Shell.dispatch("thread.jump", { index: 2 }) }
    Shortcut { sequence: "alt+3"; enabled: shell.mode === "compose"; onActivated: Shell.dispatch("thread.jump", { index: 3 }) }
    Shortcut { sequence: "alt+4"; enabled: shell.mode === "compose"; onActivated: Shell.dispatch("thread.jump", { index: 4 }) }
    Shortcut { sequence: "alt+5"; enabled: shell.mode === "compose"; onActivated: Shell.dispatch("thread.jump", { index: 5 }) }
    Shortcut { sequence: "alt+6"; enabled: shell.mode === "compose"; onActivated: Shell.dispatch("thread.jump", { index: 6 }) }
    Shortcut { sequence: "alt+7"; enabled: shell.mode === "compose"; onActivated: Shell.dispatch("thread.jump", { index: 7 }) }
    Shortcut { sequence: "alt+8"; enabled: shell.mode === "compose"; onActivated: Shell.dispatch("thread.jump", { index: 8 }) }
    Shortcut { sequence: "alt+9"; enabled: shell.mode === "compose"; onActivated: Shell.dispatch("thread.jump", { index: 9 }) }

    // The open context menu.
    Shortcut { sequence: "up"; enabled: shell.mode === "contextMenu"; onActivated: Shell.dispatch("contextMenu.move", { delta: -1 }) }
    Shortcut { sequence: "k"; enabled: shell.mode === "contextMenu"; onActivated: Shell.dispatch("contextMenu.move", { delta: -1 }) }
    Shortcut { sequence: "down"; enabled: shell.mode === "contextMenu"; onActivated: Shell.dispatch("contextMenu.move", { delta: 1 }) }
    Shortcut { sequence: "j"; enabled: shell.mode === "contextMenu"; onActivated: Shell.dispatch("contextMenu.move", { delta: 1 }) }
    Shortcut {
        sequence: "return"
        enabled: shell.mode === "contextMenu"
        onActivated: {
            const menu = Shell.state.contextMenu
            if (menu) Shell.dispatch("contextMenu.select", { requestId: menu.requestId, id: menu.items[menu.selectedIndex].id })
        }
    }
    Shortcut {
        sequence: "escape"
        enabled: shell.mode === "contextMenu"
        onActivated: {
            const menu = Shell.state.contextMenu
            if (menu) Shell.dispatch("contextMenu.select", { requestId: menu.requestId, id: null })
        }
    }

    // Rename and delete prompts.
    Shortcut { sequence: "escape"; enabled: shell.mode === "rename"; onActivated: Shell.dispatch("overlay.cancel") }
    Shortcut { sequence: "y"; enabled: shell.mode === "confirmDelete"; onActivated: Shell.dispatch("thread.delete.confirm") }
    Shortcut { sequence: "n"; enabled: shell.mode === "confirmDelete"; onActivated: Shell.dispatch("overlay.cancel") }
    Shortcut { sequence: "escape"; enabled: shell.mode === "confirmDelete"; onActivated: Shell.dispatch("overlay.cancel") }

    // The command palette.
    Shortcut { sequence: "up"; enabled: shell.mode === "command"; onActivated: Shell.dispatch("palette.move", { delta: -1 }) }
    Shortcut { sequence: "down"; enabled: shell.mode === "command"; onActivated: Shell.dispatch("palette.move", { delta: 1 }) }
    Shortcut { sequence: "escape"; enabled: shell.mode === "command"; onActivated: Shell.dispatch("palette.close") }

    // The new-thread form.
    Shortcut { sequence: "escape"; enabled: shell.mode === "newThread"; onActivated: Shell.dispatch("newThread.cancel") }

    // The source-control panel: ↑/↓ move, Enter runs, Esc hands the keys
    // back; in commit mode Esc cancels the message.
    Shortcut { sequence: "up"; enabled: shell.mode === "panel"; onActivated: Shell.dispatch("git.previous") }
    Shortcut { sequence: "down"; enabled: shell.mode === "panel"; onActivated: Shell.dispatch("git.next") }
    Shortcut { sequence: "return"; enabled: shell.mode === "panel"; onActivated: Shell.dispatch("git.activate") }
    Shortcut { sequence: "escape"; enabled: shell.mode === "panel"; onActivated: Shell.dispatch("rightPanel.blur") }
    Shortcut { sequence: "escape"; enabled: shell.mode === "commit"; onActivated: Shell.dispatch("git.commit.cancel") }

    // The settings page: PgUp/PgDn scroll, Esc closes. (DiffViewer keeps its own keys.)
    Shortcut { sequence: "escape"; enabled: shell.mode === "settings"; onActivated: Shell.dispatch("settings.close") }
    Shortcut {
        sequence: "pagedown"
        enabled: shell.mode === "settings"
        onActivated: settingsLoader.item?.scroll(Math.max(1, Shell.state.size.rows - 4))
    }
    Shortcut {
        sequence: "pageup"
        enabled: shell.mode === "settings"
        onActivated: settingsLoader.item?.scroll(-Math.max(1, Shell.state.size.rows - 4))
    }

    // The terminal drawer. Focused, every other key goes to the running program.
    Shortcut {
        sequence: "ctrl+p"
        enabled: Shell.state.terminal.open && (shell.mode === "compose" || shell.mode === "terminal")
        onActivated: Shell.dispatch("terminal.focus.toggle")
    }
    Shortcut {
        sequence: "ctrl+o"
        enabled: shell.mode === "terminal"
        onActivated: Shell.dispatch("terminal.copy")
    }
    Shortcut {
        sequence: "shift+pageup"
        enabled: shell.mode === "terminal"
        onActivated: Shell.dispatch("terminal.scroll", { action: "page-up" })
    }
    Shortcut {
        sequence: "shift+pagedown"
        enabled: shell.mode === "terminal"
        onActivated: Shell.dispatch("terminal.scroll", { action: "page-down" })
    }
    Shortcut {
        sequence: "shift+up"
        enabled: shell.mode === "terminal"
        onActivated: Shell.dispatch("terminal.scroll", { action: "line-up" })
    }
    Shortcut {
        sequence: "shift+down"
        enabled: shell.mode === "terminal"
        onActivated: Shell.dispatch("terminal.scroll", { action: "line-down" })
    }
    Shortcut {
        sequence: "ctrl+up"
        enabled: shell.mode === "terminal"
        onActivated: Shell.dispatch("terminal.resize", { delta: 2 })
    }
    Shortcut {
        sequence: "ctrl+down"
        enabled: shell.mode === "terminal"
        onActivated: Shell.dispatch("terminal.resize", { delta: -2 })
    }
    // File browser and viewer.
    Shortcut {
        sequence: "up"
        enabled: shell.mode === "files"
        onActivated: Shell.dispatch("files.move", { delta: -1 })
    }
    Shortcut {
        sequence: "down"
        enabled: shell.mode === "files"
        onActivated: Shell.dispatch("files.move", { delta: 1 })
    }
    Shortcut {
        sequence: "pageup"
        enabled: shell.mode === "files"
        onActivated: Shell.dispatch("files.page", { delta: -1 })
    }
    Shortcut {
        sequence: "pagedown"
        enabled: shell.mode === "files"
        onActivated: Shell.dispatch("files.page", { delta: 1 })
    }
    Shortcut {
        sequence: "return, right"
        enabled: shell.mode === "files"
        onActivated: Shell.dispatch("files.activate")
    }
    Shortcut {
        sequence: "left, backspace"
        enabled: shell.mode === "files"
        onActivated: Shell.dispatch("files.up")
    }
    Shortcut {
        sequence: "escape"
        enabled: shell.mode === "files"
        onActivated: Shell.dispatch("files.back")
    }
    // Adding a project: the path field keeps the typing, these move and leave.
    Shortcut {
        sequence: "up"
        enabled: shell.mode === "project"
        onActivated: Shell.dispatch("project.add.move", { delta: -1 })
    }
    Shortcut {
        sequence: "down"
        enabled: shell.mode === "project"
        onActivated: Shell.dispatch("project.add.move", { delta: 1 })
    }
    Shortcut {
        sequence: "escape"
        enabled: shell.mode === "project"
        onActivated: Shell.dispatch("project.add.back")
    }
    // The renderer does not exit on Ctrl+C; the app tears down in order. In the
    // terminal it interrupts the running program instead.
    Shortcut {
        sequence: "ctrl+c"
        enabled: shell.mode !== "terminal"
        onActivated: Shell.dispatch("app.quit")
    }
}
