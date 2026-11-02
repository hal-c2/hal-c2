pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell

// The Tools drawer of a device tab (DeviceTools, ThreadDevices' tools): the
// shown device's settings as it reported them, one control per action its
// platform has. Every change is one request to the MC; the control then
// shows what the device confirmed. The panel beside it keeps the screen
// live, with the accessibility overlay this drawer turns on.
//
//   DeviceToolsPanel { tools: Panel.device.tools }
Rectangle {
    id: root

    property var tools: null

    readonly property var view: tools ? tools.view : null
    readonly property var settings: view ? view.settings : null
    readonly property bool ios: view !== null && view.platform === "ios"
    readonly property bool disabled: view === null || view.pending || !view.loaded
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
    readonly property color borderColor: Theme.palette.color("border", "#27272a")

    objectName: "deviceTools"
    color: Theme.palette.color("surface", "#0f0f11")
    border.color: borderColor
    border.width: 1

    function labelOf(options, value) {
        for (const option of options) {
            if (option.value === value)
                return option.label;
        }
        return "";
    }
    function indexOfValue(options, value) {
        for (let n = 0; n < options.length; ++n) {
            if (options[n].value === value)
                return n;
        }
        return -1;
    }

    readonly property var textSizes: [
        { value: "small", label: qsTr("Small") },
        { value: "default", label: qsTr("Default") },
        { value: "large", label: qsTr("Large") },
        { value: "extra-large", label: qsTr("Extra large") }
    ]
    readonly property var colorFilters: [
        { value: "none", label: qsTr("None") },
        { value: "grayscale", label: qsTr("Grayscale") },
        { value: "red-green", label: qsTr("Red / green (protanopia)") },
        { value: "green-red", label: qsTr("Green / red (deuteranopia)") },
        { value: "blue-yellow", label: qsTr("Blue / yellow (tritanopia)") }
    ]
    readonly property var orientations: [
        { value: "portrait", label: qsTr("Portrait") },
        { value: "landscape_left", label: qsTr("Landscape left") },
        { value: "portrait_upside_down", label: qsTr("Upside down") },
        { value: "landscape_right", label: qsTr("Landscape right") }
    ]
    readonly property var iosPermissions: ["Camera", "Microphone", "Photos", "Contacts", "Calendar", "Reminders", "Location", "Notifications", "Motion", "Media library", "Face ID"]
    readonly property var androidPermissions: ["Camera", "Microphone", "Photos", "Contacts", "Calendar", "Location", "Notifications", "Physical activity"]
    readonly property var presets: ["San Francisco", "New York", "London", "Stockholm", "Tokyo"]

    component Section: Column {
        id: section

        property string title: ""

        width: parent ? parent.width : 0
        spacing: 6
        topPadding: 8
        bottomPadding: 8
        leftPadding: 12
        rightPadding: 12

        Text {
            text: section.title
            color: root.muted
            font.pixelSize: Math.round(11 * Theme.fontScale)
            font.weight: Font.Medium
            font.capitalization: Font.AllUppercase
        }
    }

    component ToolRow: Item {
        id: row

        property string label: ""
        default property alias content: holder.children

        width: parent ? parent.width - 24 : 0
        height: 28

        Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: row.label
            color: root.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }
        Item {
            id: holder
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width * 0.55
            height: parent.height
        }
    }

    component SwitchRow: ToolRow {
        id: switchRow

        property string setting: ""
        property var checkedValue: undefined

        ShellSwitch {
            objectName: "toolsSwitch-" + switchRow.setting
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: switchRow.checkedValue === true
            enabled: !root.disabled && switchRow.checkedValue !== undefined
            Accessible.name: switchRow.label
            onClicked: root.tools.setSwitch(switchRow.setting, checked)
        }
    }

    component ChoiceRow: ToolRow {
        id: choiceRow

        property string control: ""
        property var options: []
        property string value: ""
        property bool reported: true

        ShellComboBox {
            objectName: "toolsChoice-" + choiceRow.control
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            outline: true
            model: choiceRow.options.map(option => option.label)
            currentIndex: root.indexOfValue(choiceRow.options, choiceRow.value)
            enabled: !root.disabled && choiceRow.reported
            Accessible.name: choiceRow.label
            onActivated: index => root.tools.choose(choiceRow.control, choiceRow.options[index].label)
        }
    }

    component ToggleRow: ToolRow {
        id: toggleRow

        property string control: ""
        property var options: []
        property string value: ""
        property bool reported: true

        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            Repeater {
                model: toggleRow.options

                delegate: ShellButton {
                    required property var modelData

                    objectName: "toolsChoice-" + toggleRow.control + "-" + modelData.label
                    text: modelData.label
                    subtle: toggleRow.value !== modelData.value
                    enabled: !root.disabled && toggleRow.reported
                    Accessible.name: modelData.label
                    onClicked: root.tools.choose(toggleRow.control, modelData.label)
                }
            }
        }
    }

    component SubmitRow: ToolRow {
        id: submitRow

        property string field: ""
        property string placeholder: ""
        property string action: ""
        property bool canSubmit: true

        height: 32

        ShellTextField {
            id: fieldItem

            objectName: "toolsField-" + submitRow.field
            anchors.left: parent.left
            anchors.right: submitButton.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: submitRow.placeholder
            enabled: !root.disabled && submitRow.canSubmit
            onAccepted: submitButton.clicked()
        }
        ShellButton {
            id: submitButton

            objectName: "toolsSubmit-" + submitRow.field
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: submitRow.action
            enabled: !root.disabled && submitRow.canSubmit && fieldItem.text.trim().length > 0
            onClicked: {
                root.tools.submit(submitRow.field, fieldItem.text);
                fieldItem.text = "";
            }
        }
    }

    Column {
        width: parent.width

        Item {
            width: parent.width
            height: 36

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Tools")
                color: root.foreground
                font.pixelSize: Math.round(12 * Theme.fontScale)
                font.weight: Font.Medium
            }
            BusyIndicator {
                objectName: "toolsSpinner"
                anchors.left: parent.left
                anchors.leftMargin: 52
                anchors.verticalCenter: parent.verticalCenter
                width: 16
                height: 16
                running: visible
                visible: root.view !== null && root.view.pending
            }
            ShellButton {
                objectName: "toolsClose"
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                subtle: true
                iconName: "x"
                Accessible.name: qsTr("Close tools")
                onClicked: root.tools.setOpen(false)
            }
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: root.borderColor
            }
        }

        Text {
            objectName: "toolsError"
            x: 12
            width: parent.width - 24
            visible: root.view !== null && root.view.error.length > 0
            wrapMode: Text.Wrap
            text: root.view ? root.view.error : ""
            color: root.errorColor
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }
        Text {
            objectName: "toolsLoading"
            x: 12
            width: parent.width - 24
            visible: root.view !== null && !root.view.loaded && root.view.error.length === 0
            text: qsTr("Reading device settings…")
            color: root.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }
    }

    Flickable {
        anchors.fill: parent
        anchors.topMargin: 44
        contentHeight: sections.implicitHeight + 16
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: sections

            width: parent.width

            Section {
                title: qsTr("App")

                ToolRow {
                    label: qsTr("Foreground")

                    Text {
                        objectName: "toolsForeground"
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        horizontalAlignment: Text.AlignRight
                        elide: Text.ElideLeft
                        text: root.view ? root.view.foreground : "—"
                        color: root.foreground
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }
                }
                ToolRow {
                    visible: root.view !== null && (root.view.hasForeground || root.view.canRelaunch)
                    height: visible ? 32 : 0

                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6

                        ShellButton {
                            objectName: "toolsTerminate"
                            text: qsTr("Terminate")
                            enabled: !root.disabled
                            onClicked: root.tools.terminate()
                        }
                        ShellButton {
                            objectName: "toolsRelaunch"
                            text: qsTr("Relaunch")
                            enabled: !root.disabled
                            onClicked: root.tools.relaunch()
                        }
                    }
                }
                SubmitRow {
                    field: "url"
                    placeholder: "https://… or myapp://"
                    action: qsTr("Open")
                }
                SubmitRow {
                    field: "launch"
                    placeholder: root.ios ? qsTr("Bundle ID to launch") : qsTr("Package name to launch")
                    action: qsTr("Launch")
                }
            }

            Section {
                title: root.ios ? qsTr("Simulator") : qsTr("Emulator")

                ToggleRow {
                    label: qsTr("Appearance")
                    control: "Appearance"
                    options: [{ value: "light", label: qsTr("Light") }, { value: "dark", label: qsTr("Dark") }]
                    value: root.settings ? root.settings.appearance ?? "" : ""
                }
                ChoiceRow {
                    label: qsTr("Text size")
                    control: "Text size"
                    options: root.textSizes
                    value: root.settings ? root.settings.textSize ?? "" : ""
                }
                ToggleRow {
                    visible: root.ios
                    height: visible ? 28 : 0
                    label: qsTr("Liquid Glass")
                    control: "Liquid Glass"
                    options: [{ value: "clear", label: qsTr("Clear") }, { value: "tinted", label: qsTr("Tinted") }]
                    value: root.settings ? root.settings.liquidGlass ?? "" : ""
                    reported: root.settings !== null && root.settings.liquidGlass !== undefined
                }
                ChoiceRow {
                    visible: root.ios
                    height: visible ? 28 : 0
                    label: qsTr("Color filter")
                    control: "Color filter"
                    options: root.colorFilters
                    value: root.settings ? root.settings.colorFilter ?? "" : ""
                }
                ChoiceRow {
                    visible: !root.ios
                    height: visible ? 28 : 0
                    label: qsTr("Orientation")
                    control: "Orientation"
                    options: root.orientations
                    value: ""
                }
                SwitchRow {
                    label: qsTr("Reduce Motion")
                    setting: "Reduce Motion"
                    checkedValue: root.settings ? root.settings.reduceMotion : undefined
                }
                SwitchRow {
                    visible: root.ios
                    height: visible ? 28 : 0
                    label: qsTr("Increase Contrast")
                    setting: "Increase Contrast"
                    checkedValue: root.settings ? root.settings.increaseContrast : undefined
                }
                SwitchRow {
                    visible: root.ios
                    height: visible ? 28 : 0
                    label: qsTr("Reduce Transparency")
                    setting: "Reduce Transparency"
                    checkedValue: root.settings ? root.settings.reduceTransparency : undefined
                }
                SwitchRow {
                    visible: root.ios
                    height: visible ? 28 : 0
                    label: qsTr("Show Borders")
                    setting: "Show Borders"
                    checkedValue: root.settings ? root.settings.showBorders : undefined
                }
                SwitchRow {
                    visible: root.ios
                    height: visible ? 28 : 0
                    label: qsTr("VoiceOver")
                    setting: "VoiceOver"
                    checkedValue: root.settings ? root.settings.voiceOver : undefined
                }
                SwitchRow {
                    visible: !root.ios
                    height: visible ? 28 : 0
                    label: qsTr("Network")
                    setting: "Network"
                    checkedValue: root.settings ? root.settings.networkEnabled : undefined
                }
            }

            Section {
                title: qsTr("Accessibility")

                ToolRow {
                    label: qsTr("Overlay element frames")

                    ShellSwitch {
                        objectName: "toolsAxOverlay"
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        checked: root.view !== null && root.view.axOverlay
                        enabled: root.view !== null && root.view.axOffered
                        Accessible.name: qsTr("Overlay element frames")
                        onClicked: root.tools.setAxOverlay(checked)
                    }
                }
            }

            Section {
                title: qsTr("Location")

                Item {
                    width: parent.width - 24
                    height: 32

                    ShellTextField {
                        id: latitudeField

                        objectName: "toolsLatitude"
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: (parent.width - 6) / 2
                        placeholderText: qsTr("Latitude")
                        enabled: !root.disabled
                        onTextChanged: {
                            if (activeFocus)
                                root.tools.setLocationText(text, longitudeField.text);
                        }
                        Connections {
                            target: root.tools
                            function onViewChanged() {
                                if (latitudeField.text !== root.view.latitude && !latitudeField.activeFocus)
                                    latitudeField.text = root.view.latitude;
                            }
                        }
                    }
                    ShellTextField {
                        id: longitudeField

                        objectName: "toolsLongitude"
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: (parent.width - 6) / 2
                        placeholderText: qsTr("Longitude")
                        enabled: !root.disabled
                        onTextChanged: {
                            if (activeFocus)
                                root.tools.setLocationText(latitudeField.text, text);
                        }
                        Connections {
                            target: root.tools
                            function onViewChanged() {
                                if (longitudeField.text !== root.view.longitude && !longitudeField.activeFocus)
                                    longitudeField.text = root.view.longitude;
                            }
                        }
                    }
                }
                Item {
                    width: parent.width - 24
                    height: 32

                    readonly property bool locationValid: {
                        const lat = root.view ? root.view.latitude.trim() : "";
                        const lon = root.view ? root.view.longitude.trim() : "";
                        return lat !== "" && lon !== "" && !isNaN(Number(lat)) && !isNaN(Number(lon)) && Math.abs(Number(lat)) <= 90 && Math.abs(Number(lon)) <= 180;
                    }

                    ShellComboBox {
                        objectName: "toolsLocationPreset"
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: 132
                        outline: true
                        model: root.presets
                        currentIndex: -1
                        displayText: qsTr("Preset…")
                        enabled: !root.disabled
                        Accessible.name: qsTr("Location preset")
                        onActivated: index => root.tools.applyPreset(root.presets[index])
                    }
                    ShellButton {
                        objectName: "toolsLocationSet"
                        anchors.left: parent.left
                        anchors.leftMargin: 138
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Set")
                        enabled: !root.disabled && parent.locationValid
                        onClicked: root.tools.applyLocation()
                    }
                    ShellButton {
                        objectName: "toolsLocationClear"
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.ios
                        subtle: true
                        text: qsTr("Clear")
                        enabled: !root.disabled
                        onClicked: root.tools.clearLocation()
                    }
                }
            }

            Section {
                title: qsTr("Permissions")

                ShellTextField {
                    id: permissionApp

                    objectName: "toolsPermissionApp"
                    width: parent.width - 24
                    placeholderText: root.view && root.view.hasForeground ? root.view.foreground : qsTr("App ID")
                    enabled: !root.disabled
                }
                Item {
                    width: parent.width - 24
                    height: 32

                    readonly property string app: permissionApp.text.trim() !== "" ? permissionApp.text.trim() : root.view && root.view.hasForeground ? root.view.foreground : ""

                    ShellComboBox {
                        id: permissionChoice

                        objectName: "toolsPermission"
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: 132
                        outline: true
                        model: root.ios ? root.iosPermissions : root.androidPermissions
                        enabled: !root.disabled
                        Accessible.name: qsTr("Permission")
                    }
                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4

                        ShellButton {
                            objectName: "toolsPermissionGrant"
                            text: qsTr("Grant")
                            enabled: !root.disabled && parent.parent.app !== ""
                            onClicked: root.tools.decide(permissionApp.text, permissionChoice.currentText, "grant")
                        }
                        ShellButton {
                            objectName: "toolsPermissionRevoke"
                            text: qsTr("Revoke")
                            enabled: !root.disabled && parent.parent.app !== ""
                            onClicked: root.tools.decide(permissionApp.text, permissionChoice.currentText, "revoke")
                        }
                        ShellButton {
                            objectName: "toolsPermissionReset"
                            visible: root.ios
                            subtle: true
                            text: qsTr("Reset")
                            enabled: !root.disabled && parent.parent.app !== ""
                            onClicked: root.tools.decide(permissionApp.text, permissionChoice.currentText, "reset")
                        }
                    }
                }
            }

            Section {
                visible: root.ios
                height: visible ? implicitHeight : 0
                title: qsTr("Push notification")

                Item {
                    width: parent.width - 24
                    height: 32

                    ShellTextField {
                        id: pushField

                        objectName: "toolsPushField"
                        anchors.left: parent.left
                        anchors.right: pushSend.left
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        placeholderText: qsTr("Alert text")
                        enabled: !root.disabled && root.view !== null && root.view.hasForeground
                    }
                    ShellButton {
                        id: pushSend

                        objectName: "toolsPushSend"
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Send")
                        enabled: !root.disabled && root.view !== null && root.view.hasForeground && pushField.text.trim().length > 0
                        onClicked: {
                            root.tools.sendPush(pushField.text);
                            pushField.text = "";
                        }
                    }
                }
                Text {
                    visible: root.view !== null && !root.view.hasForeground
                    text: qsTr("Open an app first.")
                    color: root.muted
                    font.pixelSize: Math.round(11 * Theme.fontScale)
                }
            }

            Section {
                visible: root.view !== null && root.view.eventLogOffered
                height: visible ? implicitHeight : 0
                title: qsTr("Event log")

                ShellButton {
                    objectName: "toolsEventLogToggle"
                    text: root.view && root.view.eventLogOpen ? qsTr("Close event log") : qsTr("Open event log")
                    subtle: true
                    onClicked: root.tools.setEventLogOpen(!(root.view && root.view.eventLogOpen))
                }
                Column {
                    width: parent.width - 24
                    visible: root.view !== null && root.view.eventLogOpen

                    Text {
                        visible: root.view === null || root.view.events.length === 0
                        text: qsTr("No events yet.")
                        color: root.muted
                        font.pixelSize: Math.round(11 * Theme.fontScale)
                    }
                    Repeater {
                        model: root.view ? root.view.events : []

                        delegate: Text {
                            required property var modelData

                            width: parent.width
                            elide: Text.ElideRight
                            text: modelData.time + "  " + modelData.summary
                            color: root.foreground
                            font.pixelSize: Math.round(11 * Theme.fontScale)
                        }
                    }
                }
            }
        }
    }
}

