import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The phone's layout of the shell: the pairing screen until the phone has an
// environment (`pairing`), then one screen at a time for where the window is
// (`route`, NavigationController): the thread list at home, a thread or a new
// thread's draft, or settings. The system's back goes back one step and
// leaves the app from home.
ShellWindow {
    id: root

    readonly property var pairing: Shell.state.pairing ?? null
    // `connection` still says connecting once an environment is forgotten, so
    // whether there is one is always `pairing`'s to say.
    readonly property bool paired: pairing !== null && pairing.phase === "paired"
    readonly property string routeKind: route !== null ? route.kind : "home"
    readonly property string screen: !paired ? "pairing" : routeKind === "thread" || routeKind === "draft" ? "thread" : routeKind === "settings" ? "settings" : "home"
    // The settings section the route names; none on the bare settings route,
    // which is the list of them here.
    readonly property string openSection: screen === "settings" && route.section && route.section !== "/settings" ? route.section : ""
    // The two popups of the bricks that do not close on the system's back
    // by themselves (they keep Escape for their own keys).
    readonly property bool popupOpen: PaletteModel.open || Keybindings.modelPickerOpen
    readonly property bool canStepBack: paired && (routeKind !== "home" || popupOpen)

    // What the system draws over each edge of the window (the status and
    // navigation bars, a cut-out) and how far the on-screen keyboard reaches
    // up from the bottom, in the layout's pixels. Android reports the
    // keyboard's top edge in device pixels from the window's top, and may or
    // may not have resized the window for it: what is left under that edge is
    // what the keyboard covers either way.
    readonly property real keyboardTop: Qt.inputMethod.visible && Qt.inputMethod.keyboardRectangle.height > 0 ? Qt.inputMethod.keyboardRectangle.y / (Qt.platform.os === "android" ? Screen.devicePixelRatio : 1) : height
    readonly property real insetTop: SafeArea.margins.top / zoom
    readonly property real insetLeft: SafeArea.margins.left / zoom
    readonly property real insetRight: SafeArea.margins.right / zoom
    readonly property real insetBottom: Math.max(SafeArea.margins.bottom, height - keyboardTop) / zoom

    // One step back: out of an open popup, from a settings section to the
    // sections, and from anything else to where the user was before
    // (NavigationController's back stack, home when it is empty).
    function stepBack() {
        if (PaletteModel.open)
            PaletteModel.dismiss();
        else if (Keybindings.modelPickerOpen)
            Shell.dispatch("composer.modelPicker.toggle");
        else if (openSection.length > 0)
            Shell.dispatch("settings.navigate", { to: "/settings" });
        else
            Keybindings.commands.run("navigation.back");
    }

    width: 412
    height: 915
    minimumWidth: 320
    minimumHeight: 480
    firstRunGate: false
    connectionNotice: false
    contextMenus: false

    // The phone's own controls are Material's, in the Theme's colours. This
    // is the one place that names the style's attached properties; popups
    // take them from the window, and the controls from their parents.
    Material.theme: Theme.appearance === "light" ? Material.Light : Material.Dark
    Material.accent: Theme.palette.color("accent", "#2563eb")
    Material.primary: Theme.palette.color("accent", "#2563eb")
    Material.background: Theme.palette.color("toolbar", "#0b0b0d")
    Material.foreground: Theme.palette.color("text", "#e4e4e7")

    // Android's back gesture or key. Off at home and on the pairing screen,
    // where the system takes it and leaves the app.
    Shortcut {
        sequences: ["Back"]
        enabled: root.canStepBack
        onActivated: root.stepBack()
    }

    ColumnLayout {
        id: safe

        objectName: "mobileContent"
        anchors.fill: parent
        anchors.topMargin: root.insetTop
        anchors.leftMargin: root.insetLeft
        anchors.rightMargin: root.insetRight
        anchors.bottomMargin: root.insetBottom
        spacing: 0

        // How the connection is doing, while it is not live: above the
        // screen rather than over it.
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: notice.visible ? notice.height + 24 : 0
            visible: root.paired

            ConnectionNotice {
                id: notice
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            Loader {
                anchors.fill: parent
                active: root.screen === "pairing"
                sourceComponent: PairingScreen {}
            }

            // Kept while paired, so the list is where the user left it.
            Loader {
                anchors.fill: parent
                active: root.paired
                visible: root.screen === "home"
                sourceComponent: HomeScreen {
                    onEnvironmentRequested: environment.open()
                }
            }

            Loader {
                anchors.fill: parent
                active: root.screen === "thread"
                sourceComponent: ThreadScreen {
                    onBackRequested: root.stepBack()
                }
            }

            Loader {
                anchors.fill: parent
                active: root.screen === "settings"
                sourceComponent: SettingsScreen {
                    section: root.openSection
                    onBackRequested: root.stepBack()
                }
            }

            Notifications {
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.topMargin: 64
                cardWidth: Math.min(340, parent.width - 24)
            }

            EnvironmentSheet {
                id: environment
            }

            RenameThreadDialog {}

            MobileMenu {}
        }
    }
}
