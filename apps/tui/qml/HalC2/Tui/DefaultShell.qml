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

    // With no projects yet, the invitation to add one is a page in the
    // conversation's place (until the add-project box opens).
    readonly property bool inviting: Shell.state.addProject.invite && !Shell.state.addProject.open

    // The conversation (empty for a new-thread draft), or the settings page in its place.
    Conversation {
        id: conversationView
        visible: !Shell.state.settings.active && !shell.inviting && !Shell.state.layout.rightPanel.asMain
        flexGrow: 1
        flexShrink: 1
    }
    // A panel too wide to share covers the pane (ShellWindow); nothing peeks out
    // under it when the prompt and popovers leave a row spare.
    Item {
        visible: Shell.state.layout.rightPanel.asMain && !Shell.state.settings.active
        flexGrow: 1
        flexShrink: 1
    }
    Loader {
        id: settingsLoader
        active: Shell.state.settings.active
        SettingsPage { flexGrow: 1 }
    }
    Loader {
        objectName: "addProjectInviteLoader"
        active: shell.inviting && !Shell.state.settings.active
        sourceComponent: AddProjectInvite { flexGrow: 1 }
    }
    // Popovers float above the prompt, which stays in place (ChatView).
    AddProject {}
    SelectOverlay { id: selectView }
    CommandPalette { id: paletteView }
    RevertPicker {}
    ThreadOverlay {}
    // The prompt: a reply, or the first message of a new-thread draft.
    Composer { id: composerView }
    ShellKeymap {}
}
