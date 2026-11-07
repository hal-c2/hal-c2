pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Templates as T
import HalC2.Shell
import "js/settingsPages.js" as Pages

// The window every rice starts from: theme-driven colour, opacity and frame,
// the shell's own context menus, questions and error overlay, and the window
// commands (minimize / maximize / close / move). Children land in the body
// under the overlay, so a broken layout still shows its error.
Window {
    id: root

    default property alias content: body.data

    // The first-run gate and welcome wizard over the window. A client that
    // sets no machine up (the phone, which shows its pairing screen before
    // there is an MC to wait for) turns it off.
    property bool firstRunGate: true
    // The window's own ConnectionNotice at its top edge. A root that has the
    // notice elsewhere turns it off: DefaultLayout then shows it in a strip of
    // its own, and the phone places it clear of the status bar.
    property bool connectionNotice: true
    // The shell's menus (`menu`) as a popup where they were asked for. A
    // layout that draws them itself (the phone's sheet) turns it off.
    property bool contextMenus: true
    // The side panel's tab bodies, shared by the panel (RightPanel) and the
    // stage (CentreHost, ThreadArea) so a tab moving between them keeps its
    // page, stream and scroll.
    readonly property PanelBodies panelBodies: panelBodiesPool

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
    // "HAL-C2 (Dev)" or "HAL-C2 (Nightly)" for a build that is not a release (StageController).
    readonly property string appName: Shell.state.stage && Shell.state.stage.label ? qsTr("HAL-C2 (%1)").arg(Shell.state.stage.label) : qsTr("HAL-C2")
    readonly property bool settingsActive: route !== null && route.kind === "settings"
    // The settings section showing (js/settingsPages.js): layouts show
    // SettingsHost and hide the composer while settingsActive, and CentreHost
    // otherwise.
    readonly property string settingsSection: !settingsActive ? "" : Pages.resolve(route.section)
    readonly property bool terminalFocused: hasAncestor(root.activeFocusItem, "HalC2Terminal")
    // A text field has the keyboard.
    readonly property bool editableFocused: root.activeFocusItem !== null && "cursorPosition" in root.activeFocusItem
    // A browser tab's page has it (BrowserPanel), not its address field.
    readonly property bool previewFocused: !editableFocused && hasAncestor(root.activeFocusItem, "browserPage")
    // The composer's own field has it.
    readonly property bool composerFocused: editableFocused && "composerInput" in root.activeFocusItem

    function hasAncestor(item, objectName) {
        for (let node = item; node; node = node.parent) {
            if (node.objectName === objectName) {
                return true;
            }
        }
        return false;
    }

    // Whether the layout draws the thread list's slim rows and rail as the
    // window narrows (LayoutController's sidebarMode). A root whose layouts
    // were not drawn for them (the phone's tablet layout) turns it off and
    // keeps the full list.
    property bool sidebarModes: true

    // The layout fits the thread list to the room the window leaves it, and
    // widens its default for a monospace interface font.
    function reportWidth() {
        Shell.dispatch("layout.window", { width: Math.round(root.width / root.zoom), monospace: Theme.monospace, modes: root.sidebarModes });
    }
    readonly property bool monospaceInterface: Theme.monospace
    onMonospaceInterfaceChanged: reportWidth()
    onSidebarModesChanged: reportWidth()

    width: 1280
    height: 820
    onWidthChanged: reportWidth()
    // A zoom changes the room as a resize does. Later, as the layout's answer
    // republishes the zoom while it is still changing.
    onZoomChanged: Qt.callLater(reportWidth)
    // Again once the layout is there: the shell may start after the window.
    // Later, as the answer republishes sidebarWidth while it is still changing.
    onSidebarWidthChanged: Qt.callLater(reportWidth)
    Component.onCompleted: reportWidth()
    minimumWidth: 640
    minimumHeight: 400
    visible: true
    title: route !== null && route.title ? qsTr("%1 — %2").arg(route.title, appName) : appName
    color: Theme.windowTransparent ? "transparent" : Theme.palette.color("chrome", "#0b0b0d")
    opacity: Theme.windowOpacity
    flags: Theme.frameless ? Qt.Window | Qt.FramelessWindowHint : Qt.Window

    Item {
        id: body

        // The window's popups (popupHoldsKeys).
        readonly property Item overlay: T.Overlay.overlay

        objectName: "shellBody"
        width: root.width / root.zoom
        height: root.height / root.zoom
        scale: root.zoom
        transformOrigin: Item.TopLeft
    }

    // Every attached ToolTip shares one instance; this dresses it.
    ShellToolTip {
        tip: root.contentItem.T.ToolTip.toolTip
    }

    PanelBodies {
        id: panelBodiesPool
    }

    ContextMenuHost {
        objectName: "shellMenuHost"
        surfaceId: root.contextMenus ? "shell" : ""
    }

    ProjectRemovalDialog {}

    ProjectRenameDialog {}

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
            font.pixelSize: Theme.type.display.size
            font.weight: Font.DemiBold
        }
    }

    // The first-run gate: covers the window until setup is done.
    WelcomeWizard {
        id: welcomeWizard

        anchors.fill: parent
        visible: root.firstRunGate && welcomeWizard.active
    }

    ShellErrorOverlay {
        anchors.fill: parent
    }

    ConnectionNotice {
        id: windowNotice

        visible: root.connectionNotice && (windowNotice.troubled || windowNotice.warning !== null)
    }

    // One window shortcut per sequence the keymap (Keybindings) binds. A key
    // with no command in the current focus stands down and stays with the
    // focused control. A focused terminal keeps every key except the shell's
    // own terminal-context commands (Ctrl+J and co), and a text field every
    // key whose command stands down for it (mod+z). So does every key while a
    // popup holds the keyboard (popupHoldsKeys).
    //
    // A property, not a child: a shortcut under an item is one Qt stands down
    // while any popup that closes on Escape is open, wherever the keyboard is,
    // and the keys then went into the field under it (a page's `/` menu, the
    // release notes a hover opens).
    //
    // Each Shortcut is held by a QtObject. The list changes with the route,
    // the turn and the focus, and the Instantiator drops its old delegates
    // with deleteLater, which a Shortcut ignores (Qt 6.12): one that was the
    // delegate itself never went, and kept its key in the application's
    // shortcut map. The QtObject goes, and deletes its Shortcut as it does.
    property Instantiator keyShortcuts: Instantiator {
        model: Keybindings.shortcuts

        delegate: QtObject {
            id: key

            required property var modelData

            readonly property Shortcut shortcut: Shortcut {
                sequence: key.modelData.sequence
                context: Qt.WindowShortcut
                autoRepeat: key.modelData.autoRepeat
                enabled: !root.popupHoldsKeys && (root.terminalFocused ? key.modelData.terminal : root.previewFocused ? key.modelData.preview : root.composerFocused ? key.modelData.composer : root.editableFocused ? key.modelData.editable : key.modelData.chrome)
                onActivated: Keybindings.press(key.modelData.sequence, {
                    terminal: root.terminalFocused,
                    composer: root.composerFocused,
                    editable: root.editableFocused,
                    preview: root.previewFocused
                })
            }
        }
    }

    // A popup holds the window's keys while it has the keyboard (a menu, a
    // picker, a dialog's field), the command palette aside, which takes its own
    // toggle, or while it is modal and shows its scrim (ShellScrim). One that
    // leaves the keyboard where it was holds none.
    readonly property bool popupHoldsKeys: {
        const overlay = body.overlay;
        if (!overlay)
            return false;
        for (let node = root.activeFocusItem; node; node = node.parent) {
            if (node.objectName === "commandPaletteContent")
                return false;
            if (node === overlay)
                return true;
        }
        return overlay.children.some(child => child.visible && child.objectName === "shellScrim");
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
