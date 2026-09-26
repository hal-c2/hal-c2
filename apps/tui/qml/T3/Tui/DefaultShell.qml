import OpenTUI

// The built-in arrangement. A user shell.qml can use it as its root and tweak
// one piece (`DefaultShell { sidebar.width: 40 }`) or compose the bricks anew.
//
// Keys are mode-scoped Shortcuts for now; the full keymap replaces them.
ShellWindow {
    id: shell
    property alias conversation: conversationView

    readonly property var panelState: Shell.state.rightPanel
    readonly property bool panelAsMain: panelState.isOpen && Shell.state.layout.rightPanelAsMain

    // The detail row: the conversation (or the settings / diff page in its
    // place) with the source-control panel docked on the right, or standing
    // in for the conversation when the terminal is too narrow for both.
    // TODO(merge): move the panel into ShellWindow's `layout.rightPanel` slot.
    Item {
        id: detailRow
        objectName: "detailRow"
        flexDirection: "row"
        flexGrow: 1

        Item {
            objectName: "chatColumn"
            visible: !shell.panelAsMain
            flexGrow: 1
            flexDirection: "column"

            Conversation {
                id: conversationView
                visible: !Shell.state.settings.active && !Shell.state.diff.open
                flexGrow: 1
            }
            Loader {
                id: settingsLoader
                active: Shell.state.settings.active
                SettingsPage { flexGrow: 1 }
            }
            Loader {
                id: diffLoader
                active: Shell.state.diff.open
                DiffViewer { flexGrow: 1 }
            }
        }
        Loader {
            active: shell.panelState.isOpen
            RightPanel {
                flexShrink: 0
                width: shell.panelAsMain ? Shell.state.layout.mainWidth : Shell.state.layout.rightWidth
            }
        }
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

    // Source control: Ctrl+L toggles the panel; in panel mode ↑/↓ move, Enter
    // runs, Esc hands the keys back; in commit mode Esc cancels the message.
    Shortcut {
        sequence: "ctrl+l"
        enabled: Shell.state.mode === "compose" || Shell.state.mode === "panel"
        onActivated: Shell.dispatch("rightPanel.toggle")
    }
    Shortcut {
        sequence: "up"
        enabled: Shell.state.mode === "panel"
        onActivated: Shell.dispatch("git.previous")
    }
    Shortcut {
        sequence: "down"
        enabled: Shell.state.mode === "panel"
        onActivated: Shell.dispatch("git.next")
    }
    Shortcut {
        sequence: "return"
        enabled: Shell.state.mode === "panel"
        onActivated: Shell.dispatch("git.activate")
    }
    Shortcut {
        sequence: "escape"
        enabled: Shell.state.mode === "panel"
        onActivated: Shell.dispatch("rightPanel.blur")
    }
    Shortcut {
        sequence: "escape"
        enabled: Shell.state.mode === "commit"
        onActivated: Shell.dispatch("git.commit.cancel")
    }

    // Settings and diff pages: PgUp/PgDn scroll, Esc closes; the diff also
    // steps through its entries (↑/↓) and switches views (s).
    Shortcut {
        sequence: "escape"
        enabled: Shell.state.mode === "settings"
        onActivated: Shell.dispatch("settings.close")
    }
    Shortcut {
        sequence: "escape"
        enabled: Shell.state.mode === "diff"
        onActivated: Shell.dispatch("diff.close")
    }
    Shortcut {
        sequence: "up"
        enabled: Shell.state.mode === "diff"
        onActivated: Shell.dispatch("diff.previous")
    }
    Shortcut {
        sequence: "down"
        enabled: Shell.state.mode === "diff"
        onActivated: Shell.dispatch("diff.next")
    }
    Shortcut {
        sequence: "s"
        enabled: Shell.state.mode === "diff"
        onActivated: Shell.dispatch("diff.toggleView")
    }
    Shortcut {
        sequence: "pagedown"
        enabled: Shell.state.mode === "settings" || Shell.state.mode === "diff"
        onActivated: (settingsLoader.item ?? diffLoader.item)?.scroll(Math.max(1, Shell.state.size.rows - 4))
    }
    Shortcut {
        sequence: "pageup"
        enabled: Shell.state.mode === "settings" || Shell.state.mode === "diff"
        onActivated: (settingsLoader.item ?? diffLoader.item)?.scroll(-Math.max(1, Shell.state.size.rows - 4))
    }

    // The renderer does not exit on Ctrl+C; the app tears down in order.
    Shortcut { sequence: "ctrl+c"; onActivated: Shell.dispatch("app.quit") }
}
