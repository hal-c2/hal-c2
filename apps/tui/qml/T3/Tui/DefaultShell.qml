import OpenTUI

// The built-in arrangement. A user shell.qml can use it as its root and tweak
// one piece (`DefaultShell { sidebar.width: 40 }`) or compose the bricks anew.
// Keys come from ShellKeymap (chords per mode, from `Shell.state.keybindings`).
ShellWindow {
    id: shell
    property alias conversation: conversationView
    property alias composer: composerView
    property alias palette: paletteView
    property alias select: selectView

    Conversation { id: conversationView; flexGrow: 1 }
    CommandPalette { id: paletteView }
    SelectOverlay { id: selectView }
    Composer { id: composerView }
    ShellKeymap {}
}
