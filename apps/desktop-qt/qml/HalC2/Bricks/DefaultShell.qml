import QtQuick
import HalC2.Shell
import HalC2.Bricks

// Built-in shell: a window filled with the built-in layout (DefaultLayout).
// A user's ~/.hal-c2/shell/shell.qml replaces this file wholesale; it is also
// the fallback when that file fails to load.
// Frameless windows get their drag handle and window buttons from the
// sidebar band and the header strip rather than a separate title bar.
// Pages MC plugins add are tabs above it all (DefaultLayout).
ShellWindow {
    id: root

    // DefaultLayout then shows the connection notice in its own strip.
    connectionNotice: false

    // Local QML extensions can customize one brick without copying the layout.
    property alias sidebar: layout.sidebar
    property alias composer: layout.composer
    property alias workspace: layout.workspace
    property alias centreView: layout.centreView
    property alias terminalDrawer: layout.terminalDrawer
    property alias rightPanel: layout.rightPanel
    property alias toolbar: layout.toolbar
    property alias navigationPanel: layout.navigationPanel

    DefaultLayout {
        id: layout

        anchors.fill: parent
        window: root
    }
}
