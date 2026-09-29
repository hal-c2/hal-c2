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
    readonly property var screen: view ? view.screen : null
    readonly property var stream: source ? source.stream : null
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
    readonly property color border: Theme.palette.color("border", "#27272a")

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
        font.pixelSize: 12
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
            font.pixelSize: 12
        }

        ShellButton {
            anchors.horizontalCenter: parent.horizontalCenter
            text: qsTr("Open Integrations settings")
            onClicked: Shell.dispatch("settings.navigate", {
                to: "/settings/integrations"
            })
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
                anchors.right: tools.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                text: root.screen ? root.screen.description : qsTr("Choose a device")
                elide: Text.ElideRight
                color: root.muted
                font.pixelSize: 12
            }

            Row {
                id: tools

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
                color: root.border
            }
        }

        Note {
            objectName: "deviceHostDetail"
            text: root.view ? root.view.hostDetail : ""
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
                font.pixelSize: 12
            }

            ShellButton {
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
            anchors.fill: parent
            anchors.margins: 8
            visible: root.screen !== null
            focus: visible
            activeFocusOnTab: true
            Accessible.role: Accessible.Client
            Accessible.name: root.screen && root.screen.platform === "ios" ? qsTr("iOS Simulator screen") : qsTr("Android Emulator screen")

            readonly property real aspect: root.stream ? root.stream.aspect : 9 / 19.5
            readonly property int turn: root.stream ? root.stream.rotation : 0
            readonly property bool sideways: turn === 90 || turn === -90

            // The largest box at the device's aspect that fits.
            Item {
                id: frame

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

                MouseArea {
                    anchors.fill: parent
                    enabled: root.stream !== null && root.stream.inputConnected
                    preventStealing: true

                    function send(phase, mouse) {
                        root.stream.touch(phase, mouse.x / width, mouse.y / height);
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
                    onCanceled: root.stream.touch("end", 0, 0)
                }
            }

            // Keys go to the device, except the app's own shortcuts.
            Keys.onPressed: event => {
                if (!root.stream || (event.modifiers & Qt.ControlModifier)) {
                    event.accepted = false;
                    return;
                }
                root.stream.key(event.key, event.text, (event.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) !== 0, true);
                event.accepted = true;
            }
            Keys.onReleased: event => {
                if (!root.stream || (event.modifiers & Qt.ControlModifier)) {
                    event.accepted = false;
                    return;
                }
                root.stream.key(event.key, event.text, false, false);
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
                    font.pixelSize: 12
                }

                ShellButton {
                    objectName: "deviceReconnect"
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.stream !== null && root.stream.status === "error"
                    text: qsTr("Reconnect")
                    onClicked: root.stream.reconnect()
                }
            }
        }

        // --- Waiting ---------------------------------------------------------------

        Text {
            objectName: "deviceLoading"
            anchors.centerIn: parent
            width: parent.width - 32
            visible: root.screen === null && root.view !== null && root.view.loading.length > 0
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: root.view ? root.view.loading : ""
            color: root.muted
            font.pixelSize: 12
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
                    font.pixelSize: 12
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
                                font.pixelSize: 12
                                font.weight: Font.Medium
                            }
                        }

                        Repeater {
                            model: group.modelData.devices

                            delegate: AbstractButton {
                                id: row

                                required property var modelData
                                readonly property bool pending: root.view.pendingKey === modelData.key

                                objectName: "deviceRow-" + modelData.id
                                width: group.width
                                height: 46
                                enabled: root.view.pendingKey.length === 0
                                hoverEnabled: true
                                Accessible.role: Accessible.Button
                                Accessible.name: modelData.action + " " + modelData.name
                                onClicked: root.source.open(modelData.hostId, modelData.id)
                                background: Rectangle {
                                    radius: 6
                                    border.color: root.border
                                    color: row.hovered || row.visualFocus ? Theme.palette.color("surfaceRaised", "#1f1f24") : "transparent"
                                }

                                Text {
                                    x: 12
                                    y: 6
                                    width: parent.width - 80
                                    text: row.modelData.name
                                    elide: Text.ElideRight
                                    color: root.foreground
                                    font.pixelSize: 13
                                }
                                Text {
                                    x: 12
                                    y: 25
                                    width: parent.width - 80
                                    text: row.modelData.detail
                                    elide: Text.ElideRight
                                    color: root.muted
                                    font.pixelSize: 11
                                }
                                Text {
                                    anchors.right: parent.right
                                    anchors.rightMargin: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: row.pending ? qsTr("…") : row.modelData.action
                                    color: root.muted
                                    font.pixelSize: 12
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
                    font.pixelSize: 11
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
}
