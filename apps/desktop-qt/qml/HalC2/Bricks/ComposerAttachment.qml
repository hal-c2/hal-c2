import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell

// One attachment of a draft or of an answer: an image's thumbnail, its name (a
// Snap Shot's app and window instead), how its upload stands, and taking it
// off again. `attachment` is the shell's {id, name, kind, status, error,
// source, preview}; `preview` is a draft image's thumbnail, empty for one Qt
// cannot read.
Row {
    id: chip

    required property var attachment
    readonly property var source: attachment.source ?? null
    readonly property bool failed: attachment.status === "failed"
    readonly property string label: source !== null ? (source.windowTitle.length > 0 ? qsTr("%1 · %2").arg(source.appName).arg(source.windowTitle) : source.appName) : attachment.name

    signal removeRequested
    signal retryRequested
    // The attachment opened to look at.
    signal openRequested

    spacing: 2

    Rectangle {
        id: tile

        readonly property bool pictured: thumbnail.status === Image.Ready

        objectName: "attachment-" + chip.attachment.id
        visible: chip.attachment.kind !== "file" && chip.attachment.preview !== undefined
        width: 64
        height: 64
        radius: 2
        color: Qt.alpha(Theme.palette.color("text", "#e4e4e7"), 0.04)
        border.color: Qt.alpha(Theme.palette.color("text", "#e4e4e7"), 0.12)

        Image {
            id: thumbnail
            objectName: "attachmentThumbnail"
            anchors.fill: parent
            anchors.margins: 1
            source: chip.attachment.preview ?? ""
            fillMode: Image.PreserveAspectCrop
            clip: true
        }
        ShellIcon {
            visible: !tile.pictured
            anchors.centerIn: parent
            name: "image"
            size: 20
            color: Theme.palette.color("iconMuted", "#8b8b93")
        }
        HoverHandler {
            id: tileHover
        }
        ToolTip.visible: tileHover.hovered
        ToolTip.delay: 500
        ToolTip.text: chip.label
        ShellButton {
            id: removeTile
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: 2
            implicitWidth: 18
            implicitHeight: 18
            iconName: "x"
            iconSize: 12
            Accessible.name: qsTr("Remove %1").arg(chip.label)
            background: Rectangle {
                radius: 9
                color: Qt.alpha(Theme.palette.color("canvas", "#0f0f12"), 0.8)
                border.color: removeTile.focusRing
                border.width: removeTile.visualFocus ? 1 : 0
            }
            onClicked: chip.removeRequested()
        }
    }

    ShellButton {
        objectName: "attachment:" + chip.attachment.name
        implicitHeight: 24
        iconName: chip.attachment.kind === "file" ? "file-text" : "image"
        text: chip.failed ? qsTr("%1 (upload failed)").arg(chip.label) : chip.attachment.status === "uploading" ? qsTr("%1 (uploading…)").arg(chip.label) : chip.label
        tint: chip.failed ? Theme.palette.color("error", "#f87171") : Theme.palette.color("text", "#e4e4e7")
        font.pixelSize: Math.round(12 * Theme.fontScale)
        Accessible.name: qsTr("Remove %1").arg(chip.label)
        ToolTip.visible: hovered && chip.failed && ToolTip.text.length > 0
        ToolTip.text: chip.attachment.error ?? ""
        onClicked: chip.removeRequested()
    }

    ShellButton {
        objectName: "attachmentOpen:" + chip.attachment.name
        implicitHeight: 24
        subtle: true
        iconName: "maximize-2"
        iconSize: 12
        Accessible.name: qsTr("Open %1").arg(chip.label)
        onClicked: chip.openRequested()
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
                font.pixelSize: Math.round(12 * Theme.fontScale)
                font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
                wrapMode: Text.Wrap
            }
        }
    }
}
