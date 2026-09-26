import OpenTUI

// The built-in arrangement. A user shell.qml can use it as its root and tweak
// one piece (`DefaultShell { sidebar.width: 40 }`) or compose the bricks anew.
// Keys come from ShellKeymap (chords per mode, from `Shell.state.keybindings`;
// the user's keymap.json overrides them).
ShellWindow {
    id: shell
    property alias conversation: conversationView
    property alias composer: composerView
    property alias palette: paletteView
    property alias select: selectView

    // The detail panel fills `layout.rightPanel` by its kind: source control.
    rightPanelComponent: Shell.state.layout.rightPanel.kind === "sourceControl"
        ? sourceControlPanel
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
    // The thread's terminal fills `layout.drawer` under the conversation.
    drawerComponent: terminalDrawer
    Component {
        id: terminalDrawer
        TerminalDrawer { flexGrow: 1 }
    }

    // Adding a project (and, with none yet, the invitation to) is a page in
    // the conversation's place.
    readonly property bool addingProject: Shell.state.addProject.open || Shell.state.addProject.invite

    // The conversation (empty for a new-thread draft), or the settings page in its place.
    Conversation {
        id: conversationView
        visible: !Shell.state.settings.active && !shell.addingProject
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
    CommandPalette { id: paletteView }
    SelectOverlay { id: selectView }
    ThreadOverlay {
        height: Shell.state.layout.composerRows
    }
    // The prompt: a reply, or the first message of a new-thread draft.
    Composer {
        id: composerView
        visible: Shell.state.overlay === null
            && !Shell.state.settings.active
            && !shell.addingProject
    }
    ShellKeymap {}
}
