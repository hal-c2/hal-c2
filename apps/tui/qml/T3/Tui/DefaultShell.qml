import OpenTUI

// The built-in arrangement. A user shell.qml can use it as its root and tweak
// one piece (`DefaultShell { sidebar.width: 40 }`) or compose the bricks anew.
//
// The global keymap is unnamed, so top-level entries in the user's
// keymap.json override it (`{"ctrl+p": "palette.open", "ctrl+n": null}`);
// named sections reach named keymaps such as the thread list's "list".
// Mode-scoped keys stay Shortcuts.
ShellWindow {
    id: shell
    property alias conversation: conversationView
    property alias composerActions: composerActionsView
    property alias keymap: globalKeymap

    Conversation { id: conversationView; flexGrow: 1 }
    ComposerActions { id: composerActionsView }

    Keymap {
        id: globalKeymap
        objectName: "globalKeymap"
        bindings: ({
            "ctrl+k": "palette.open",
            "ctrl+n": "thread.new",
            // The renderer does not exit on Ctrl+C; the app tears down in order.
            "ctrl+c": "quit"
        })
        // Keymap action names are the host's, except "quit".
        onActivated: (action) => Shell.dispatch(action === "quit" ? "app.quit" : action)
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
}
