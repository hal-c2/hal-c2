import QtQuick
import HalC2.Shell
import "js/settingsPages.js" as Pages
import "js/centreViews.js" as Centre

// The window every rice starts from: theme-driven colour, opacity and frame,
// the shell's own context menus, questions and error overlay, and the page's window
// commands (minimize / maximize / close / move). Children land in the body
// under the overlay, so a broken layout still shows its error.
Window {
    id: root

    default property alias content: body.data

    // Whether the thread list is hidden (LayoutController, sidebar.toggle).
    readonly property bool sidebarCollapsed: Shell.state.layout ? Shell.state.layout.sidebarCollapsed : false
    // Where the window is (NavigationController).
    readonly property var route: Shell.state.route ?? null
    readonly property bool settingsActive: route !== null && route.kind === "settings"
    // The settings section showing, and whether the shell renders it itself
    // (js/settingsPages.js): layouts put SettingsHost where the page would be
    // and hide the page and composer.
    readonly property string settingsSection: !settingsActive ? "" : Pages.resolve(route.section)
    readonly property bool nativeSettingsOpen: settingsActive && Pages.brickFor(settingsSection).length > 0
    // Whether the shell draws the route's centre itself (js/centreViews.js):
    // layouts put CentreHost where the page would be.
    readonly property bool nativeCentreOpen: route !== null && !settingsActive && Centre.brickFor(route.kind).length > 0
    // Whether the embedded page is what the centre shows.
    readonly property bool pageOpen: !nativeSettingsOpen && !nativeCentreOpen
    readonly property bool webFocused: isWebItem(root.activeFocusItem)
    readonly property bool terminalFocused: hasAncestor(root.activeFocusItem, "HalC2Terminal")
    // A text field has the keyboard (the web's editableFocus).
    readonly property bool editableFocused: root.activeFocusItem !== null && root.activeFocusItem.cursorPosition !== undefined

    function isWebItem(item) {
        return hasAncestor(item, "HalC2WebSurface");
    }

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
    minimumWidth: 640
    minimumHeight: 400
    visible: true
    title: route !== null && route.title ? qsTr("%1 — HAL-C2").arg(route.title) : qsTr("HAL-C2")
    color: Theme.windowTransparent ? "transparent" : Theme.palette.color("chrome", "#0b0b0d")
    opacity: Theme.windowOpacity
    flags: Theme.frameless ? Qt.Window | Qt.FramelessWindowHint : Qt.Window

    Item {
        id: body

        anchors.fill: parent
    }

    ContextMenuHost {
        surfaceId: "shell"
    }

    ContextMenuHost {
        surfaceId: "shell"
        stateKey: "menu"
        selectAction: "menu.select"
    }

    ProjectRemovalDialog {}

    ConfirmDialog {}

    CommandPalette {}

    ShellErrorOverlay {
        anchors.fill: parent
    }

    // One window shortcut per sequence the keymap (Keybindings) binds. A
    // command the shell runs natively fires whatever has focus, a focused page
    // included, so the page never sees the key too. A page command stands
    // down while the page is focused (it handles its own keydown) and reaches
    // it through Keybindings.press otherwise. A focused terminal keeps every
    // key except the shell's own terminal-context commands (Ctrl+J and co).
    Instantiator {
        model: Keybindings.shortcuts

        delegate: Shortcut {
            required property var modelData

            sequence: modelData.sequence
            context: Qt.WindowShortcut
            enabled: root.terminalFocused ? modelData.terminal : root.webFocused ? modelData.page : true
            onActivated: Keybindings.press(modelData.sequence, {
                page: root.webFocused,
                terminal: root.terminalFocused,
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
