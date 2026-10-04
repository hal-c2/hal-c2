import QtQuick
import HalC2.Shell
import "js/settingsPages.js" as Pages

// The window every rice starts from: theme-driven colour, opacity and frame,
// the shell's own context menus, questions and error overlay, and the window
// commands (minimize / maximize / close / move). Children land in the body
// under the overlay, so a broken layout still shows its error.
Window {
    id: root

    default property alias content: body.data

    // Whether the thread list is hidden (LayoutController, sidebar.toggle).
    readonly property bool sidebarCollapsed: Shell.state.layout ? Shell.state.layout.sidebarCollapsed : false
    // How wide the thread list is drawn (LayoutController: the width the user
    // dragged it to, less when the window leaves it no room).
    readonly property int sidebarWidth: Shell.state.layout ? (Shell.state.layout.sidebarWidth ?? 256) : 256
    // The app's zoom (LayoutController, mod+= / mod+- / mod+0): the body
    // scales, and the menu hosts and overlays stay in window coordinates, so
    // a menu opened at a pointer's scenePosition lands under it.
    readonly property real zoom: Shell.state.layout ? (Shell.state.layout.zoom ?? 1) : 1
    // Where the window is (NavigationController).
    readonly property var route: Shell.state.route ?? null
    readonly property bool settingsActive: route !== null && route.kind === "settings"
    // The settings section showing (js/settingsPages.js): layouts show
    // SettingsHost and hide the composer while settingsActive, and CentreHost
    // otherwise.
    readonly property string settingsSection: !settingsActive ? "" : Pages.resolve(route.section)
    readonly property bool terminalFocused: hasAncestor(root.activeFocusItem, "HalC2Terminal")
    // A text field has the keyboard (the web's editableFocus).
    readonly property bool editableFocused: root.activeFocusItem !== null && root.activeFocusItem.cursorPosition !== undefined
    // The composer's own field has it (the web's composerFocus).
    readonly property bool composerFocused: editableFocused && root.activeFocusItem.composerInput === true

    function hasAncestor(item, objectName) {
        for (let node = item; node; node = node.parent) {
            if (node.objectName === objectName) {
                return true;
            }
        }
        return false;
    }

    width: 1280
    height: 820
    // The layout fits the thread list to the room the window leaves it.
    onWidthChanged: Shell.dispatch("layout.window", { width: Math.round(width / zoom) })
    // Again once the layout is there: the shell may start after the window.
    onSidebarWidthChanged: Shell.dispatch("layout.window", { width: Math.round(width / zoom) })
    Component.onCompleted: Shell.dispatch("layout.window", { width: Math.round(width / zoom) })
    minimumWidth: 640
    minimumHeight: 400
    visible: true
    title: route !== null && route.title ? qsTr("%1 — HAL-C2").arg(route.title) : qsTr("HAL-C2")
    color: Theme.windowTransparent ? "transparent" : Theme.palette.color("chrome", "#0b0b0d")
    opacity: Theme.windowOpacity
    flags: Theme.frameless ? Qt.Window | Qt.FramelessWindowHint : Qt.Window

    Item {
        id: body

        objectName: "shellBody"
        width: root.width / root.zoom
        height: root.height / root.zoom
        scale: root.zoom
        transformOrigin: Item.TopLeft
    }

    ContextMenuHost {
        objectName: "shellMenuHost"
        surfaceId: "shell"
    }

    ProjectRemovalDialog {}

    ConfirmDialog {}

    CustomSnoozeDialog {}

    PullRequestThreadDialog {}

    EditFromHereDialog {}

    ProjectActionEditor {}

    ProjectIconPicker {}

    AttachmentViewer {}

    CommandPalette {}

    // The theme editor (Themes.editorOpen): the palette's "Toggle theme
    // editor", its shortcut, and Settings → Appearance open it.
    ThemeEditor {}

    // Its colour picker: over the layout, under the menus and dialogs.
    ThemeInspector {
        anchors.fill: parent
    }

    // The quit shortcut's hint (QuitController): hold, or press again.
    Rectangle {
        readonly property var hint: Shell.state.quitHint ?? null

        objectName: "quitHint"
        visible: hint !== null
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.round(root.height * 0.22)
        width: quitHintText.implicitWidth + 64
        height: quitHintText.implicitHeight + 32
        radius: height / 2
        color: Qt.rgba(0.25, 0.25, 0.25, 0.95)

        Text {
            id: quitHintText

            anchors.centerIn: parent
            text: parent.hint ? parent.hint.message : ""
            color: "white"
            font.pixelSize: Math.round(24 * Theme.fontScale)
            font.bold: true
        }
    }

    // The first-run gate: covers the window until setup is done.
    WelcomeWizard {
        anchors.fill: parent
    }

    ShellErrorOverlay {
        anchors.fill: parent
    }

    ConnectionNotice {}

    // One window shortcut per sequence the keymap (Keybindings) binds. A key
    // with no command in the current focus stands down and stays with the
    // focused control. A focused terminal keeps every key except the shell's
    // own terminal-context commands (Ctrl+J and co), and a text field every
    // key whose command stands down for it (mod+z).
    Instantiator {
        model: Keybindings.shortcuts

        delegate: Shortcut {
            required property var modelData

            sequence: modelData.sequence
            context: Qt.WindowShortcut
            autoRepeat: modelData.autoRepeat
            enabled: root.terminalFocused ? modelData.terminal : root.composerFocused ? modelData.composer : root.editableFocused ? modelData.editable : modelData.chrome
            onActivated: Keybindings.press(modelData.sequence, {
                terminal: root.terminalFocused,
                composer: root.composerFocused,
                editable: root.editableFocused
            })
        }
    }

    Connections {
        target: Shell
        function onWindowCommandRequested(command) {
            switch (command) {
            case "minimize":
                root.showMinimized();
                break;
            case "maximize":
                root.visibility === Window.Maximized ? root.showNormal() : root.showMaximized();
                break;
            case "close":
                root.close();
                break;
            case "move":
                root.startSystemMove();
                break;
            case "raise":
                if (root.visibility === Window.Minimized) root.showNormal();
                root.raise();
                root.requestActivate();
                break;
            }
        }
    }
}
