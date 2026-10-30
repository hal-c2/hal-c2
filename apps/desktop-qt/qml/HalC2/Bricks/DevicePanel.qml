pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell

// The right panel's Device tabs, from ThreadDevices (Panel.device): the
// picker lists the environment's simulators and emulators, and a device tab
// shows its device's live screen, taking touches and keys, with its hardware
// buttons above. See ThreadDevices.h for `view`.
//
//   DevicePanel { anchors.fill: parent; source: Panel.device }
Rectangle {
    id: root

    property var source: null

    readonly property var view: source ? source.view : null
    // No screen is an undefined entry of the view: null, as the bindings compare.
    readonly property var screen: view && view.screen ? view.screen : null
    readonly property var stream: source ? source.stream : null
    readonly property var tools: source ? source.tools : null
    readonly property bool toolsOpen: tools !== null && tools.view.open
    // The 3D body view, and an iPad's Magic Keyboard: panel choices, so
    // they survive switching between the views.
    property bool show3d: false
    property bool keyboardAttached: false
    readonly property bool tablet: screen !== null && String(screen.name).indexOf("iPad") >= 0

    function toggleKeyboard() {
        keyboardAttached = !keyboardAttached;
        // A Magic Keyboard is a landscape thing: turn a portrait iPad.
        if (keyboardAttached && stream && stream.orientation.indexOf("portrait") === 0)
            stream.setOrientation("landscape_left");
    }
    // The tools sit beside the screen from this width, and over it below.
    readonly property bool toolsBeside: width >= 720
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
    readonly property color borderColor: Theme.palette.color("border", "#27272a")

    objectName: "devicePanel"
    color: Theme.palette.color("surface", "#0f0f11")

    component DeviceButton: ShellButton {
        subtle: true
        ToolTip.visible: hovered
        ToolTip.text: Accessible.name
    }

    component Note: Text {
        x: 12
        width: root.width - 24
        height: visible ? implicitHeight + 12 : 0
        topPadding: 6
        bottomPadding: 6
        visible: text.length > 0
        wrapMode: Text.Wrap
        color: root.muted
        font.pixelSize: Math.round(12 * Theme.fontScale)
    }

    // The hub is off or was never set up: that happens in Settings.
    Column {
        objectName: "deviceSetup"
        anchors.centerIn: parent
        width: Math.min(parent.width - 32, 360)
        spacing: 12
        visible: root.view !== null && root.view.setup

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: qsTr("Device support is off for this environment. Turn it on in Settings to stream simulators and emulators here.")
            color: root.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        ShellButton {
            objectName: "deviceOpenSettings"
            anchors.horizontalCenter: parent.horizontalCenter
            text: qsTr("Open Integrations settings")
            onClicked: Shell.dispatch("settings.navigate", {
                to: "/settings/integrations"
            })
        }

        DeviceBanners {
            width: parent.width
            visible: root.view !== null && root.view.banners.length > 0
            source: root.source
            namePrefix: "deviceSetupBanner"
        }
    }

    Column {
        id: top

        width: parent.width
        visible: root.view !== null && !root.view.setup

        Item {
            id: header

            width: parent.width
            height: 36

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 12
                anchors.right: headerTools.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                text: root.screen ? root.screen.description : qsTr("Choose a device")
                elide: Text.ElideRight
                color: root.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }

            Row {
                id: headerTools

                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                visible: root.screen !== null

                DeviceButton {
                    objectName: "deviceHome"
                    iconName: "house"
                    Accessible.name: qsTr("Home")
                    enabled: root.stream !== null && root.stream.inputConnected
                    onClicked: root.stream.pressButton("home")
                }
                DeviceButton {
                    objectName: "deviceBack"
                    visible: root.screen !== null && root.screen.platform === "android"
                    iconName: "chevron-left"
                    Accessible.name: qsTr("Back")
                    enabled: root.stream !== null && root.stream.inputConnected
                    onClicked: root.stream.pressButton("back")
                }
                DeviceButton {
                    objectName: "deviceRecents"
                    visible: root.screen !== null && root.screen.platform === "android"
                    iconName: "square"
                    Accessible.name: qsTr("Recents")
                    enabled: root.stream !== null && root.stream.inputConnected
                    onClicked: root.stream.pressButton("recents")
                }
                DeviceButton {
                    objectName: "deviceRotate"
                    visible: root.screen !== null && root.screen.platform === "ios"
                    iconName: "rotate-ccw"
                    Accessible.name: qsTr("Rotate")
                    enabled: root.stream !== null && root.stream.inputConnected
                    onClicked: root.stream.rotate()
                }
                DeviceButton {
                    objectName: "device3dToggle"
                    iconName: "box"
                    Accessible.name: root.show3d ? qsTr("Show flat view") : qsTr("Show in 3D")
                    onClicked: root.show3d = !root.show3d
                }
                DeviceButton {
                    objectName: "deviceKeyboardToggle"
                    visible: root.tablet
                    iconName: "keyboard"
                    Accessible.name: root.keyboardAttached ? qsTr("Detach Magic Keyboard") : qsTr("Attach Magic Keyboard")
                    onClicked: root.toggleKeyboard()
                }
                DeviceButton {
                    objectName: "deviceTools"
                    iconName: "sliders-horizontal"
                    Accessible.name: qsTr("Tools")
                    onClicked: root.tools.setOpen(!root.toolsOpen)
                }
                DeviceButton {
                    objectName: "deviceFloat"
                    iconName: "picture-in-picture-2"
                    Accessible.name: qsTr("Float device over chat")
                    onClicked: root.source.floatDevice()
                }
                DeviceButton {
                    objectName: "devicePowerOff"
                    iconName: "power"
                    Accessible.name: qsTr("Power off")
                    onClicked: root.source.powerOff()
                }
                DeviceButton {
                    objectName: "deviceClose"
                    iconName: "x"
                    Accessible.name: qsTr("Close")
                    onClicked: root.source.close()
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: root.borderColor
            }
        }

        Note {
            objectName: "deviceHostDetail"
            text: root.view ? root.view.hostDetail : ""
        }
        DeviceBanners {
            x: 12
            width: root.width - 24
            visible: root.view !== null && root.view.banners.length > 0
            source: root.source
        }
        Note {
            objectName: "deviceStarting"
            text: root.view ? root.view.starting : ""
        }

        Item {
            objectName: "deviceError"
            width: parent.width
            height: visible ? errorText.implicitHeight + 12 : 0
            visible: root.view !== null && root.view.error.length > 0

            Text {
                id: errorText

                x: 12
                y: 6
                width: parent.width - 48
                wrapMode: Text.Wrap
                text: root.view ? root.view.error : ""
                color: root.errorColor
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }

            ShellButton {
                objectName: "deviceDismissError"
                anchors.right: parent.right
                anchors.rightMargin: 6
                y: 2
                subtle: true
                iconName: "x"
                Accessible.name: qsTr("Dismiss device error")
                onClicked: root.source.dismissError()
            }
        }
    }

    Item {
        id: body

        anchors.top: top.bottom
        anchors.bottom: parent.bottom
        width: parent.width
        visible: top.visible

        // --- The device's screen ---------------------------------------------------

        Item {
            id: stage

            objectName: "deviceStage"
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.margins: 8
            width: parent.width - (root.toolsOpen && root.toolsBeside ? 296 : 0)
            visible: root.screen !== null
            focus: visible
            activeFocusOnTab: true
            Accessible.role: Accessible.Client
            Accessible.name: root.screen && root.screen.platform === "ios" ? qsTr("iOS Simulator screen") : qsTr("Android Emulator screen")

            readonly property real aspect: root.stream ? root.stream.aspect : 9 / 19.5
            readonly property int turn: root.stream ? root.stream.rotation : 0
            readonly property bool sideways: turn === 90 || turn === -90

            // The largest box at the device's aspect that fits.
            Loader {
                objectName: "deviceBodyLoader"
                anchors.fill: parent
                active: root.show3d
                visible: root.show3d
                source: "DeviceBody3D.qml"
                onLoaded: {
                    item.stream = Qt.binding(() => root.stream);
                    item.deviceName = Qt.binding(() => root.screen ? root.screen.name : "");
                    item.platform = Qt.binding(() => root.screen ? root.screen.platform : "");
                    item.keyboardAttached = Qt.binding(() => root.keyboardAttached);
                }
            }

            Item {
                id: frame

                visible: !root.show3d
                anchors.centerIn: parent
                width: Math.min(stage.width, stage.height * stage.aspect)
                height: Math.min(stage.height, stage.width / stage.aspect)

                // iOS streams its portrait framebuffer while held sideways:
                // the picture takes the turned box and turns into place.
                DeviceScreen {
                    objectName: "deviceScreen"
                    anchors.centerIn: parent
                    width: stage.sideways ? frame.height : frame.width
                    height: stage.sideways ? frame.width : frame.height
                    rotation: stage.turn
                    stream: root.screen ? root.stream : null
                    visible: hasFrame
                }

                // The accessibility elements, over the picture as shown.
                Item {
                    objectName: "deviceAxOverlay"
                    anchors.fill: parent
                    visible: root.tools !== null && root.tools.view.axOverlay

                    Repeater {
                        model: root.tools ? root.tools.view.axElements : []

                        delegate: Rectangle {
                            required property var modelData

                            x: modelData.x * parent.width
                            y: modelData.y * parent.height
                            width: modelData.width * parent.width
                            height: modelData.height * parent.height
                            color: "transparent"
                            border.color: Theme.palette.color("accent", "#2563eb")
                            border.width: 1

                            Text {
                                objectName: "deviceAxLabel"
                                anchors.left: parent.left
                                anchors.bottom: parent.top
                                text: modelData.label
                                color: Theme.palette.color("accent", "#2563eb")
                                font.pixelSize: Math.round(10 * Theme.fontScale)
                            }
                        }
                    }
                }

                MouseArea {
                    objectName: "deviceTouch"
                    anchors.fill: parent
                    enabled: root.stream !== null && root.stream.inputConnected
                    preventStealing: true

                    // Where the touch last was: a cancelled touch ends there.
                    property real lastX: 0
                    property real lastY: 0

                    function send(phase, mouse) {
                        lastX = mouse.x / width;
                        lastY = mouse.y / height;
                        root.stream.touch(phase, lastX, lastY);
                    }

                    onPressed: mouse => {
                        stage.forceActiveFocus();
                        send("begin", mouse);
                    }
                    onPositionChanged: mouse => {
                        if (pressed)
                            send("move", mouse);
                    }
                    onReleased: mouse => send("end", mouse)
                    onCanceled: {
                        if (root.stream)
                            root.stream.touch("end", lastX, lastY);
                    }
                }
            }

            // Keys go to the device, except the app's own shortcuts: Ctrl
            // chords stay with the app, and so do Command chords but for
            // Command+R, which the device takes (upstream's one exception).
            function appOwns(event) {
                if (event.key === Qt.Key_Meta || event.key === Qt.Key_Control)
                    return true;
                if (event.modifiers & Qt.ControlModifier)
                    return true;
                if ((event.modifiers & Qt.MetaModifier) && event.key !== Qt.Key_R)
                    return true;
                return false;
            }
            Keys.onPressed: event => {
                if (!root.stream || stage.appOwns(event)) {
                    event.accepted = false;
                    return;
                }
                root.stream.key(event.key, event.text, (event.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) !== 0, true);
                event.accepted = true;
            }
            Keys.onReleased: event => {
                if (!root.stream || stage.appOwns(event)) {
                    event.accepted = false;
                    return;
                }
                root.stream.key(event.key, event.text, (event.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) !== 0, false);
                event.accepted = true;
            }

            Column {
                objectName: "deviceStatus"
                anchors.centerIn: parent
                width: Math.min(parent.width - 32, 320)
                spacing: 10
                visible: root.stream !== null && root.stream.status !== "streaming"

                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: !root.stream ? "" : root.stream.status === "error" ? root.stream.detail : qsTr("Connecting to the device…")
                    color: root.stream && root.stream.status === "error" ? root.errorColor : root.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }

                ShellButton {
                    objectName: "deviceReconnect"
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.stream !== null && root.stream.status === "error"
                    text: qsTr("Reconnect")
                    onClicked: root.stream.reconnect()
                }

                Text {
                    objectName: "deviceProgress"
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.stream !== null && root.stream.status === "connecting"
                    text: qsTr("Step 2 of 2: connect video")
                    color: root.muted
                    font.pixelSize: Math.round(11 * Theme.fontScale)
                }
            }

            // A lost input connection is said over the picture, which stays.
            Text {
                objectName: "deviceInputStatus"
                anchors.top: parent.top
                anchors.topMargin: 8
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.stream !== null && root.stream.status === "streaming" && !root.stream.inputConnected
                text: root.stream && root.stream.inputDetail ? qsTr("Input disconnected (%1), reconnecting…").arg(root.stream.inputDetail) : qsTr("Input disconnected, reconnecting…")
                color: root.errorColor
                font.pixelSize: Math.round(11 * Theme.fontScale)
            }
        }

        // --- The tools, beside the screen when there is room, over it else ---

        DeviceToolsPanel {
            objectName: "deviceToolsPanel"
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            width: Math.min(288, parent.width)
            z: 2
            visible: root.screen !== null && root.toolsOpen
            tools: root.tools
        }

        // --- Waiting ---------------------------------------------------------------

        Column {
            anchors.centerIn: parent
            width: parent.width - 32
            spacing: 8
            visible: root.screen === null && root.view !== null && root.view.loading.length > 0

            Text {
                objectName: "deviceLoading"
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: root.view ? root.view.loading : ""
                color: root.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }
            Text {
                objectName: "deviceOpeningProgress"
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.view !== null && root.view.pendingKey.length > 0
                text: qsTr("Step 1 of 2: open device")
                color: root.muted
                font.pixelSize: Math.round(11 * Theme.fontScale)
            }
        }

        // --- The picker ------------------------------------------------------------

        Flickable {
            id: picker

            objectName: "devicePicker"
            anchors.fill: parent
            visible: root.screen === null && root.view !== null && root.view.loading.length === 0
            contentHeight: list.implicitHeight + 32
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: list

                x: 16
                y: 16
                width: picker.width - 32
                spacing: 16

                Text {
                    objectName: "deviceEmpty"
                    width: parent.width
                    visible: root.view !== null && root.view.empty.length > 0
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: root.view ? root.view.empty : ""
                    color: root.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }

                Repeater {
                    model: root.view ? root.view.groups : []

                    delegate: Column {
                        id: group

                        required property var modelData

                        width: list.width
                        spacing: 6

                        Row {
                            spacing: 8

                            ShellIcon {
                                name: "smartphone"
                                size: 14
                                color: root.muted
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text: group.modelData.title
                                color: root.muted
                                font.pixelSize: Math.round(12 * Theme.fontScale)
                                font.weight: Font.Medium
                            }
                        }

                        Repeater {
                            model: group.modelData.devices

                            delegate: AbstractButton {
                                id: row

                                required property var modelData
                                readonly property bool pending: root.view.pendingKey === modelData.key

                                objectName: "deviceRow-" + modelData.tab
                                width: group.width
                                height: 46
                                enabled: root.view.pendingKey.length === 0
                                hoverEnabled: true
                                Accessible.role: Accessible.Button
                                Accessible.name: modelData.action + " " + modelData.name
                                onClicked: root.source.open(modelData.hostId, modelData.id)
                                background: Rectangle {
                                    radius: 6
                                    border.color: root.borderColor
                                    color: row.hovered || row.visualFocus ? Theme.palette.color("surfaceRaised", "#1f1f24") : "transparent"
                                }

                                Text {
                                    x: 12
                                    y: 6
                                    width: parent.width - 80
                                    text: row.modelData.name
                                    elide: Text.ElideRight
                                    color: root.foreground
                                    font.pixelSize: Math.round(13 * Theme.fontScale)
                                }
                                Text {
                                    x: 12
                                    y: 25
                                    width: parent.width - 80
                                    text: row.modelData.detail
                                    elide: Text.ElideRight
                                    color: root.muted
                                    font.pixelSize: Math.round(11 * Theme.fontScale)
                                }
                                Text {
                                    anchors.right: parent.right
                                    anchors.rightMargin: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: row.pending ? qsTr("…") : row.modelData.action
                                    color: root.muted
                                    font.pixelSize: Math.round(12 * Theme.fontScale)
                                }
                            }
                        }
                    }
                }

                Text {
                    width: parent.width
                    visible: root.view !== null && root.view.noAndroid
                    wrapMode: Text.Wrap
                    text: qsTr("No Android virtual devices found. Create one in Android Studio's Device Manager, then refresh.")
                    color: root.muted
                    font.pixelSize: Math.round(11 * Theme.fontScale)
                }

                ShellButton {
                    objectName: "deviceRefresh"
                    visible: root.view !== null && root.view.canRefresh
                    anchors.horizontalCenter: root.view && root.view.groups.length > 0 ? undefined : parent.horizontalCenter
                    subtle: root.view !== null && root.view.groups.length > 0
                    text: qsTr("Refresh devices")
                    onClicked: root.source.refresh()
                }
            }
        }
    }

    // First use (or support turned off): the setup wizard, in front of the
    // tab. Behind it the tab still points at the Integrations settings.
    Rectangle {
        anchors.fill: parent
        visible: root.view !== null && (root.view.wizard ?? null) !== null
        color: Qt.alpha(Theme.palette.color("canvas", "#000000"), 0.55)
        z: 5

        MouseArea {
            anchors.fill: parent
        }

        DeviceSetup {
            anchors.centerIn: parent
            width: Math.min(parent.width - 32, 440)
            height: Math.min(implicitHeight > 0 ? implicitHeight : 560, parent.height - 32)
            source: root.source
        }
    }
}
