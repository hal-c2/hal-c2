pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// What an image block shows (a row of Spaces.blocks): the image, scaled when it
// is decoded and off the UI thread, in a place held for it at its known shape;
// or what happened to it, in words, with the way back from the trash. The bytes
// are untrusted: a file that will not decode says so too.
Rectangle {
    id: holder

    required property string imageId
    // shown, trashed or deleted.
    required property string state_
    required property string url
    required property int naturalWidth
    required property int naturalHeight
    property bool readOnly: false

    readonly property bool showing: state_ === "shown" && picture.status !== Image.Error
    readonly property string says: {
        if (state_ === "trashed")
            return qsTr("This image is in the trash.");
        if (state_ === "deleted")
            return qsTr("This image was deleted.");
        return picture.status === Image.Error ? qsTr("This image could not be shown.") : "";
    }

    height: showing ? Math.min(naturalWidth > 0 ? width * naturalHeight / naturalWidth : 240, 540) : 44
    radius: Theme.radiusMd
    color: Theme.palette.color("muted", "#27272a")
    clip: true

    Image {
        id: picture

        objectName: "spaceBlockPicture"
        anchors.fill: parent
        visible: holder.showing
        source: holder.state_ === "shown" ? holder.url : ""
        sourceSize: Qt.size(1440, 1440)
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        // A new address for the same bytes must not blank the picture.
        retainWhileLoading: true
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.space.sm
        anchors.rightMargin: Theme.space.sm
        visible: holder.says !== ""
        spacing: 8

        ShellIcon {
            name: "image"
            size: 16
            color: Theme.palette.color("iconMuted", "#a1a1aa")
        }

        Text {
            objectName: "spaceBlockImageSays"
            Layout.fillWidth: true
            text: holder.says
            elide: Text.ElideRight
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Theme.type.body.size
        }

        ShellButton {
            objectName: "spaceBlockImageRestore"
            subtle: true
            visible: holder.state_ === "trashed" && !holder.readOnly
            iconName: "archive-restore"
            text: qsTr("Restore")
            onClicked: Shell.dispatch("space.image.restore", { imageId: holder.imageId })
        }
    }
}
