import OpenTUI

// The built-in arrangement. A user shell.qml can use it as its root and tweak
// one piece (`DefaultShell { sidebar.width: 40 }`) or compose the bricks anew.
//
// Keys are mode-scoped Shortcuts for now; the full keymap replaces them.
ShellWindow {
    id: shell
    property alias conversation: conversationView

    Conversation { id: conversationView; flexGrow: 1 }

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
    // The renderer does not exit on Ctrl+C; the app tears down in order.
    Shortcut { sequence: "ctrl+c"; onActivated: Shell.dispatch("app.quit") }
}
