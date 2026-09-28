import QtQuick
import HalC2.Shell
import "js/settingsPages.js" as Pages

// The window every rice starts from: theme-driven colour, opacity and frame,
// the shell's own context menus and error overlay, and the page's window
// commands (minimize / maximize / close / move). Children land in the body
// under the overlay, so a broken layout still shows its error.
Window {
    id: root

    default property alias content: body.data

    // The page still owns collapsing (Mod+B) and its own settings sections;
    // the shell animates and re-arranges around them.
    readonly property bool sidebarCollapsed: Shell.state.layout ? Shell.state.layout.sidebarCollapsed : false
    // Where the window is (NavigationController); the page's own settings
    // state until the shell has its node.
    readonly property var route: Shell.state.route ?? null
    // Settings show, from the page's sections or the shell's own pages.
    readonly property bool settingsActive: route !== null ? route.kind === "settings" : (Shell.state.settings ? Shell.state.settings.active : false)
    // The settings section showing, and whether the shell renders it itself
    // (js/settingsPages.js): layouts put SettingsHost where the page would be
    // and hide the page and composer.
    readonly property string settingsSection: !settingsActive ? "" : Pages.resolve(route !== null ? route.section : Shell.state.settings.activeSection)
    readonly property bool nativeSettingsOpen: settingsActive && Pages.brickFor(settingsSection).length > 0
    // The page's keybindings (the configurable ones from Settings), as Qt
    // sequences. They fire only while the chrome owns the keyboard: a
    // focused page sees its own keydowns and handles them itself.
    readonly property var keybindings: Shell.state.keybindings ?? []
    readonly property bool webFocused: isWebItem(root.activeFocusItem)
    // A focused terminal takes its keys too, as the page's terminal does;
    // the drawer's own shortcuts are the ones that apply there.
    readonly property bool terminalFocused: hasAncestor(root.activeFocusItem, "HalC2Terminal")
    // The terminal drawer is native, so its toggle is the shell's own; the
    // page's entry for the same chord stands down so the two never collide.
    readonly property string terminalToggleSequence: "Ctrl+J"

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

    ShellErrorOverlay {
        anchors.fill: parent
    }

    Instantiator {
        model: root.keybindings

        delegate: Shortcut {
            required property var modelData

            sequence: modelData.sequence
            context: Qt.WindowShortcut
            enabled: !root.webFocused && !root.terminalFocused && modelData.sequence !== root.terminalToggleSequence
            onActivated: Shell.dispatch("keybinding.press", {
                key: modelData.key,
                ctrlKey: modelData.ctrlKey,
                metaKey: modelData.metaKey,
                shiftKey: modelData.shiftKey,
                altKey: modelData.altKey
            })
        }
    }

    // Fires over a focused page too: its web view only claims editing keys.
    Shortcut {
        sequence: root.terminalToggleSequence
        context: Qt.WindowShortcut
        enabled: Terminals.available
        onActivated: Shell.dispatch("terminal.toggle")
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
            }
        }
    }
}
