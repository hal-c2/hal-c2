import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell

// One attachment of a draft or of an answer: its name (a Snap Shot's app and
// window instead), how its upload stands, and taking it off again.
// `attachment` is the shell's {id, name, kind, status, error, source}.
Row {
    id: chip

    required property var attachment
    readonly property var source: attachment.source ?? null
    readonly property bool failed: attachment.status === "failed"
    readonly property string label: source !== null ? (source.windowTitle.length > 0 ? qsTr("%1 · %2").arg(source.appName).arg(source.windowTitle) : source.appName) : attachment.name

    signal removeRequested
    signal retryRequested

    spacing: 2

    ShellButton {
        objectName: "attachment:" + chip.attachment.name
        implicitHeight: 24
        iconName: chip.attachment.kind === "file" ? "file-text" : "image"
        text: chip.failed ? qsTr("%1 (upload failed)").arg(chip.label) : chip.attachment.status === "uploading" ? qsTr("%1 (uploading…)").arg(chip.label) : chip.label
        tint: chip.failed ? Theme.palette.color("error", "#f87171") : Theme.palette.color("text", "#e4e4e7")
        font.pixelSize: 12
        Accessible.name: qsTr("Remove %1").arg(chip.label)
        ToolTip.visible: hovered && chip.failed && chip.attachment.error.length > 0
        ToolTip.text: chip.attachment.error
        onClicked: chip.removeRequested()
    }

    ShellButton {
        objectName: "attachmentRetry:" + chip.attachment.name
        visible: chip.failed
        implicitHeight: 24
        subtle: true
        iconName: "refresh-cw"
        iconSize: 12
        Accessible.name: qsTr("Retry uploading %1").arg(chip.label)
        onClicked: chip.retryRequested()
    }

    ShellButton {
        objectName: "attachmentAccessibility:" + chip.attachment.name
        visible: chip.source !== null
        implicitHeight: 24
        subtle: true
        iconName: "eye"
        iconSize: 12
        Accessible.name: qsTr("Accessibility data")
        onClicked: details.open()

        Popup {
            id: details
            objectName: "attachmentAccessibilityData"

            y: -height - 4
            width: 320
            padding: 10

            background: Rectangle {
                color: Theme.palette.color("surfaceOverlay", "#18181b")
                border.color: Qt.alpha(Theme.palette.color("text", "#e4e4e7"), 0.1)
                radius: 10
            }

            contentItem: Text {
                objectName: "attachmentAccessibilityText"
                text: chip.source ? chip.source.accessibility : ""
                color: Theme.palette.color("text", "#e4e4e7")
                font.pixelSize: 12
                font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Qt.application.font.family
                wrapMode: Text.Wrap
            }
        }
    }
}
