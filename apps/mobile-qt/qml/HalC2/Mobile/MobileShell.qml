import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The Android client's window: the pairing screen until the device has an
// environment (`pairing`), and again when it asks to pair with another or is
// opened with a pairing link, with the camera over it while a pairing code is
// scanned (`scanner`). Otherwise the layout the window has room for. That is
// the desktop's own (DefaultLayout) wherever its thread list and thread fit
// side by side, and below that the phone layout, one screen at a time for
// where the window is (`route`, NavigationController): the thread list at
// home, a thread or a new thread's draft, or settings. Both follow the same
// route and controllers, so a window that is resized, rotated or unfolded
// stays where it was.
ShellWindow {
    id: root

    readonly property var pairing: Shell.state.pairing ?? null
    // `connection` still says connecting once an environment is forgotten, so
    // whether there is one is always `pairing`'s to say.
    readonly property bool paired: pairing !== null && pairing.phase === "paired"
    // A paired device at the pairing screen, its environment still its own.
    readonly property bool adding: pairing !== null && pairing.adding === true
    readonly property bool scanning: (Shell.state.scanner ?? null)?.open === true
    readonly property bool connected: (Shell.state.connection ?? null)?.phase === "connected"

    // The on-screen keyboard. Android reports it in device pixels from the
    // window's top, and may or may not have resized the window for it:
    // `keyboardTop` is where it starts either way, and `fullHeight` what the
    // window is with it down.
    readonly property rect keyboard: Qt.inputMethod.keyboardRectangle
    readonly property bool keyboardUp: Qt.inputMethod.visible && keyboard.height > 0
    readonly property real keyboardScale: Qt.platform.os === "android" ? Screen.devicePixelRatio : 1
    readonly property real keyboardTop: keyboardUp ? keyboard.y / keyboardScale : height
    readonly property real fullHeight: keyboardUp ? Math.max(height, keyboardTop + keyboard.height / keyboardScale) : height
    // What the system draws over each edge of the window (the status and
    // navigation bars, a cut-out) and how far the keyboard reaches up from the
    // bottom, in the layouts' pixels.
    readonly property real insetTop: SafeArea.margins.top / zoom
    readonly property real insetLeft: SafeArea.margins.left / zoom
    readonly property real insetRight: SafeArea.margins.right / zoom
    readonly property real insetBottom: Math.max(SafeArea.margins.bottom, height - keyboardTop) / zoom

    // Whether the desktop's layout fits, on the window in the layouts' pixels
    // (dp on a device, less the zoom) with the keyboard down: its thread list
    // beside its thread is 736 wide (LayoutController's 256 and 480, inside
    // Android's medium window width class), and under 480 tall is that
    // platform's compact height class, a phone on its side.
    readonly property bool roomy: width / zoom >= 736 && fullHeight / zoom >= 480
    // What the window shows: `pairing`, or the layout it has room for.
    readonly property string layout: !paired || adding ? "pairing" : roomy ? "desktop" : "phone"

    readonly property string routeKind: route !== null ? route.kind : "home"
    // The phone layout's screen for the route.
    readonly property string screen: routeKind === "thread" || routeKind === "draft" ? "thread" : routeKind === "settings" ? "settings" : "home"
    // The settings section the route names; none on the bare settings route,
    // which is the list of them in the phone layout.
    readonly property string openSection: screen === "settings" && route.section && route.section !== "/settings" ? route.section : ""
    // The two popups of the bricks that do not close on the system's back
    // by themselves (they keep Escape for their own keys).
    readonly property bool popupOpen: PaletteModel.open || Keybindings.modelPickerOpen
    // The phone layout's home is where its steps back end; the desktop
    // layout has no such screen, and ends where the route has nothing before it.
    readonly property bool canStepBack: scanning || adding || (paired && (popupOpen || (roomy ? route !== null && route.canGoBack === true : routeKind !== "home")))

    // One step back: out of the scanner, from pairing with another
    // environment to the one the device has, out of an open popup, in the
    // phone layout from a settings section to the sections, and from anything
    // else to where the user was before (NavigationController's back stack,
    // home when it is empty).
    function stepBack() {
        if (scanning)
            Shell.dispatch("scanner.close");
        else if (adding)
            Shell.dispatch("pairing.cancel");
        else if (PaletteModel.open)
            PaletteModel.dismiss();
        else if (Keybindings.modelPickerOpen)
            Shell.dispatch("composer.modelPicker.toggle");
        else if (layout === "phone" && openSection.length > 0)
            Shell.dispatch("settings.navigate", { to: "/settings" });
        else
            Keybindings.commands.run("navigation.back");
    }

    width: 412
    height: 915
    minimumWidth: 320
    minimumHeight: 320
    // What the phone layout turns off of the desktop's window, and the
    // desktop layout keeps: the first-run wizard (once there is an
    // environment to set up), and menus as popups at the pointer rather than
    // the phone's sheet. The app is told which layout shows (MobileApp): a
    // window with no thread lands on a draft in the desktop layout and stays
    // on the thread list in the phone's, which also draws no terminal.
    firstRunGate: layout === "desktop" && connected
    contextMenus: layout === "desktop"
    onLayoutChanged: Shell.dispatch("layout.desktop", { shown: layout === "desktop" })
    Component.onCompleted: Shell.dispatch("layout.desktop", { shown: layout === "desktop" })
    // The notice is placed below, clear of the system's bars, in both layouts.
    connectionNotice: false

    // The client's own controls are Material's, in the Theme's colours. This
    // is the one place that names the style's attached properties; popups
    // take them from the window, and the controls from their parents.
    Material.theme: Theme.appearance === "light" ? Material.Light : Material.Dark
    Material.accent: Theme.palette.color("accent", "#2563eb")
    Material.primary: Theme.palette.color("accent", "#2563eb")
    Material.background: Theme.palette.color("toolbar", "#0b0b0d")
    Material.foreground: Theme.palette.color("text", "#e4e4e7")

    // Android's back gesture or key. Off where there is no step back, where
    // the system takes it and leaves the app.
    Shortcut {
        sequences: ["Back"]
        enabled: root.canStepBack
        onActivated: root.stepBack()
    }

    ColumnLayout {
        objectName: "mobileContent"
        anchors.fill: parent
        anchors.topMargin: root.insetTop
        anchors.leftMargin: root.insetLeft
        anchors.rightMargin: root.insetRight
        anchors.bottomMargin: root.insetBottom
        spacing: 0

        // How the connection is doing, while it is not live: above the layout
        // rather than over it. Settings need the connection, so the way out
        // of an environment that does not come back is here too.
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: !notice.visible ? 0 : notice.height + 24 + (forget.visible ? forget.height + 4 : 0)
            visible: root.layout !== "pairing"

            ConnectionNotice {
                id: notice
            }

            MobileButton {
                id: forget

                objectName: "connectionForget"
                anchors.top: notice.bottom
                anchors.topMargin: 4
                anchors.right: notice.right
                visible: notice.visible && notice.troubled
                subtle: true
                tint: Theme.palette.color("error", "#ef4444")
                text: qsTr("Forget this environment")
                onClicked: Shell.dispatch("pairing.askToForget")
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            Loader {
                anchors.fill: parent
                active: root.layout === "pairing"
                sourceComponent: PairingScreen {
                    // Under the scanner, out of the keyboard's reach.
                    enabled: !root.scanning
                }
            }

            // The camera, only while a pairing code is being scanned.
            Loader {
                anchors.fill: parent
                z: 1
                active: root.layout === "pairing" && root.scanning
                sourceComponent: ScanScreen {}
            }

            Loader {
                anchors.fill: parent
                active: root.layout === "desktop"
                sourceComponent: DefaultLayout {
                    objectName: "desktopLayout"
                    window: root
                    // A tablet's or a touchscreen laptop's list is under a
                    // finger as well as a pointer.
                    sidebar.touchRows: true
                    // Android frames the window itself: nothing here is its
                    // drag handle or carries its buttons.
                    framesWindow: false
                }
            }

            Loader {
                anchors.fill: parent
                active: root.layout === "phone"
                sourceComponent: Item {
                    objectName: "phoneLayout"

                    // Kept while the layout is, so the list is where the user left it.
                    HomeScreen {
                        anchors.fill: parent
                        visible: root.screen === "home"
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
                        maximumHeight: parent.height - anchors.topMargin - 12
                        opaque: true
                    }

                    RenameThreadDialog {}

                    MobileMenu {}
                }
            }
        }
    }
}
