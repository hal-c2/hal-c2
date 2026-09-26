import OpenTUI

// The built-in arrangement. A user shell.qml can use it as its root and tweak
// one piece (`DefaultShell { sidebar.width: 40 }`) or compose the bricks anew.
//
// Keys are mode-scoped Shortcuts for now; the full keymap replaces them.
ShellWindow {
    id: shell
    property alias conversation: conversationView
    readonly property string mode: Shell.state.mode

    Conversation {
        id: conversationView
        visible: Shell.state.page.kind !== "draft"
        flexGrow: 1
        flexShrink: 1
    }
    NewThreadForm { flexGrow: 1; flexShrink: 1 }
    CommandPalette {}
    ThreadOverlay {
        height: Shell.state.layout.composerRows
    }
    PromptBox {
        visible: Shell.state.overlay === null && Shell.state.page.kind !== "draft"
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
        enabled: shell.mode === "compose"
        onActivated: Shell.dispatch("rightPanel.toggle", { kind: "sourceControl" })
    }
    Shortcut {
        sequence: "ctrl+e"
        enabled: shell.mode === "compose"
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

    // The renderer does not exit on Ctrl+C; the app tears down in order.
    Shortcut { sequence: "ctrl+c"; onActivated: Shell.dispatch("app.quit") }
}
