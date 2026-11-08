pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The open Space's images, or those in its trash: a list a finger wide of scaled
// thumbnails, so only the rows on screen fetch and decode anything. An image comes
// from a file, or from the words of the prompt under the list with the image model
// picked beside them (ComposerController's images prompt); its menu has what can
// be done with it.
ColumnLayout {
    id: view

    required property Item screen
    readonly property var space: Shell.state.space ?? ({})
    readonly property bool adding: space.addingImage === true
    readonly property bool generating: space.generatingImage === true
    property bool trashShown: false

    objectName: "spaceImagesView"
    spacing: 0

    MobileBar {
        Layout.fillWidth: true
        title: view.trashShown ? qsTr("Images in the trash") : qsTr("Images")
        canGoBack: true
        onBackRequested: view.screen.backRequested()

        MobileIconButton {
            objectName: "spaceImageAdd"
            enabled: !view.adding
            iconName: "file"
            label: qsTr("Add from a file")
            onClicked: view.screen.askImageFile()
        }

        MobileIconButton {
            objectName: "spaceImagesTrash"
            iconName: view.trashShown ? "image" : "trash"
            label: view.trashShown ? qsTr("Images") : qsTr("Images in the trash")
            onClicked: view.trashShown = !view.trashShown
        }
    }

    Label {
        objectName: "spaceImageBusy"
        Layout.fillWidth: true
        Layout.margins: 16
        Layout.bottomMargin: 4
        visible: view.adding || view.generating
        wrapMode: Text.Wrap
        text: view.generating ? qsTr("Generating an image…") : qsTr("Adding the image…")
        color: Theme.palette.color("textMuted", "#a1a1aa")
        font.pixelSize: Math.round(13 * Theme.fontScale)
    }

    ListView {
        objectName: "spaceImageRows"
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        // Hidden behind another step, it fetches nothing.
        model: !view.visible ? null : view.trashShown ? Spaces.imageTrash : Spaces.images

        delegate: Item {
            id: card

            required property var model

            objectName: "spaceImage:" + model.name
            width: ListView.view.width
            implicitHeight: 72

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 4
                spacing: 12

                Rectangle {
                    Layout.preferredWidth: 56
                    Layout.preferredHeight: 56
                    radius: Math.min(Theme.radius, 8)
                    color: Theme.palette.color("muted", "#27272a")
                    clip: true

                    Image {
                        id: thumbnail

                        objectName: "spaceImageThumbnail"
                        anchors.fill: parent
                        source: card.model.url
                        // A thumbnail, whatever the size of the file.
                        sourceSize: Qt.size(168, 168)
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        // A new address for the same bytes must not blank the picture.
                        retainWhileLoading: true

                        // Whether the last load to finish left a picture. A renewal's load keeps it;
                        // paintedWidth can't tell, as it keeps its value when the picture has gone.
                        property bool hasPicture: false

                        onStatusChanged: if (status !== Image.Loading) hasPicture = status === Image.Ready
                    }

                    ShellIcon {
                        objectName: "spaceImagePlaceholder"
                        anchors.centerIn: parent
                        visible: !thumbnail.hasPicture
                        name: "image"
                        size: 18
                        color: Theme.palette.color("iconMuted", "#a1a1aa")
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    Label {
                        Layout.fillWidth: true
                        text: card.model.name
                        elide: Text.ElideMiddle
                        font.pixelSize: Math.round(15 * Theme.fontScale)
                    }

                    Label {
                        Layout.fillWidth: true
                        visible: card.model.prompt !== ""
                        text: card.model.prompt
                        elide: Text.ElideRight
                        color: Theme.palette.color("textMuted", "#a1a1aa")
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                    }
                }

                MobileIconButton {
                    objectName: "spaceImageMenu:" + card.model.name
                    iconName: "ellipsis"
                    label: qsTr("Actions for this image")
                    onClicked: view.trashShown ? view.screen.imageTrashMenu(card.model.id) : view.screen.imageMenu(card.model.id)
                }
            }
        }

        footer: Label {
            objectName: "spaceImagesEmpty"
            width: ListView.view.width
            padding: 24
            visible: ListView.view.count === 0
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Math.round(14 * Theme.fontScale)
            text: view.trashShown ? qsTr("The trash is empty.") : qsTr("%1 has no images yet. Add one from a file, or describe one below to generate it.").arg(Spaces.spaceName)
        }
    }

    Composer {
        objectName: "spaceImagesComposer"
        // The phone keeps the effort and options as chips.
        optionsInModelControl: false
        Layout.fillWidth: true
        imagesHost: true
        visible: !view.trashShown && ready
    }
}
