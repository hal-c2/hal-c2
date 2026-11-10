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

    // Whether the user may take it away; an answer on its way keeps its files.
    property bool removable: true
    signal removeRequested
    signal retryRequested
    // The attachment opened to look at.
    signal openRequested

    spacing: Theme.space.xxs

    Rectangle {
        id: tile

        readonly property bool pictured: thumbnail.status === Image.Ready

        objectName: "attachment-" + chip.attachment.id
        visible: chip.attachment.kind !== "file" && chip.attachment.preview !== undefined
        width: Theme.control.lg * 2
        height: Theme.control.lg * 2
        radius: Theme.radiusXs
        color: Qt.alpha(Theme.palette.color("text", "#e4e4e7"), 0.04)
        border.color: Qt.alpha(Theme.palette.color("text", "#e4e4e7"), 0.12)

        Image {
            id: thumbnail
            objectName: "attachmentThumbnail"
            Accessible.name: chip.label
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
            size: Theme.icon.lg
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
            anchors.margins: Theme.space.xxs
            implicitWidth: Theme.icon.lg
            implicitHeight: Theme.icon.lg
            visible: chip.removable
            iconName: "x"
            iconSize: Theme.icon.sm
            Accessible.name: qsTr("Remove %1").arg(chip.label)
            background: Rectangle {
                radius: Theme.radiusPill
                color: Qt.alpha(Theme.palette.color("canvas", "#0f0f12"), 0.8)
                border.color: removeTile.focusRing
                border.width: removeTile.visualFocus ? 1 : 0
            }
            onClicked: chip.removeRequested()
        }
    }

    ShellButton {
        objectName: "attachment:" + chip.attachment.name
        implicitHeight: Theme.control.sm
        iconName: chip.attachment.kind === "file" ? "file-text" : "image"
        text: chip.failed ? qsTr("%1 (upload failed)").arg(chip.label) : chip.attachment.status === "uploading" ? (chip.attachment.progress ?? -1) >= 0 ? qsTr("%1 (uploading %2%)").arg(chip.label).arg(Math.round(chip.attachment.progress * 100)) : qsTr("%1 (uploading…)").arg(chip.label) : chip.label
        tint: chip.failed ? Theme.palette.color("errorForeground", "#f87171") : Theme.palette.color("text", "#e4e4e7")
        font.pixelSize: Theme.type.meta.size
        Accessible.name: chip.removable ? qsTr("Remove %1").arg(chip.label) : chip.label
        ToolTip.visible: hovered && chip.failed && ToolTip.text.length > 0
        ToolTip.text: chip.attachment.error ?? ""
        onClicked: if (chip.removable) chip.removeRequested()
    }

    ShellButton {
        objectName: "attachmentOpen:" + chip.attachment.name
        implicitHeight: Theme.control.sm
        subtle: true
        iconName: "maximize-2"
        iconSize: Theme.icon.sm
        Accessible.name: qsTr("Open %1").arg(chip.label)
        onClicked: chip.openRequested()
    }

    ShellButton {
        objectName: "attachmentRetry:" + chip.attachment.name
        visible: chip.failed
        implicitHeight: Theme.control.sm
        subtle: true
        iconName: "refresh-cw"
        iconSize: Theme.icon.sm
        Accessible.name: qsTr("Retry uploading %1").arg(chip.label)
        onClicked: chip.retryRequested()
    }

    ShellButton {
        objectName: "attachmentAccessibility:" + chip.attachment.name
        visible: chip.source !== null
        implicitHeight: Theme.control.sm
        subtle: true
        iconName: "eye"
        iconSize: Theme.icon.sm
        Accessible.name: qsTr("Accessibility data")
        onClicked: details.open()

        Popup {
            id: details
            objectName: "attachmentAccessibilityData"

            y: -height - Theme.space.xs
            width: 320
            padding: Theme.space.sm

            background: ShellPopoverSurface {}

            contentItem: Text {
                objectName: "attachmentAccessibilityText"
                text: chip.source ? chip.source.accessibility : ""
                color: Theme.palette.color("text", "#e4e4e7")
                font.pixelSize: Theme.type.meta.size
                wrapMode: Text.Wrap
            }
        }
    }
}
