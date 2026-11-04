pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// The Space's images (Spaces.images), or those in its trash (Spaces.imageTrash),
// as a grid of thumbnails: only the cards on screen fetch and decode anything,
// each scaled as it is decoded. An image in the trash comes back or goes for good.
Rectangle {
    id: browser

    objectName: "spaceImagesBrowser"

    readonly property var space: Shell.state.space ?? ({})
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    property bool trashShown: false

    signal addRequested
    signal generateRequested
    signal closeRequested

    color: Theme.palette.color("canvas", "#09090b")

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 24
        spacing: 12

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space.sm

            ShellButton {
                objectName: "spaceImagesClose"
                subtle: true
                iconName: "chevron-left"
                Accessible.name: qsTr("Back to the page")
                onClicked: browser.closeRequested()
            }

            Text {
                Layout.fillWidth: true
                text: browser.trashShown ? qsTr("Images in the trash") : qsTr("Images")
                elide: Text.ElideRight
                color: browser.foreground
                font.pixelSize: Theme.type.display.size
                font.weight: Font.DemiBold
            }

            ShellButton {
                objectName: "spaceImageAdd"
                iconName: "file"
                text: browser.space.addingImage === true ? qsTr("Adding…") : qsTr("Add from a file")
                enabled: browser.space.addingImage !== true
                onClicked: browser.addRequested()
            }

            ShellButton {
                objectName: "spaceImageGenerate"
                primary: true
                iconName: "plus"
                text: browser.space.generatingImage === true ? qsTr("Generating…") : qsTr("Generate")
                enabled: browser.space.generatingImage !== true
                onClicked: browser.generateRequested()
            }

            ShellButton {
                objectName: "spaceImagesTrash"
                subtle: true
                iconName: browser.trashShown ? "image" : "trash"
                text: browser.trashShown ? qsTr("Images") : Spaces.imageTrash.count > 0 ? qsTr("Trash (%1)").arg(Spaces.imageTrash.count) : qsTr("Trash")
                onClicked: browser.trashShown = !browser.trashShown
            }
        }

        ShellEmptyState {
            objectName: "spaceImagesEmpty"
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Theme.space.xxl
            visible: grid.count === 0
            iconName: browser.trashShown ? "trash" : "image"
            title: browser.trashShown ? qsTr("The trash is empty") : qsTr("No images yet")
            description: browser.trashShown ? "" : qsTr("Add one from a file or generate one from a prompt.")
        }

        GridView {
            id: grid

            objectName: "spaceImageGrid"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            cellWidth: 212
            cellHeight: 216
            boundsBehavior: Flickable.StopAtBounds
            model: browser.trashShown ? Spaces.imageTrash : Spaces.images

            delegate: Item {
                id: card

                required property string id
                required property string name
                required property string prompt
                required property string url

                objectName: "spaceImage:" + name
                width: GridView.view.cellWidth
                height: GridView.view.cellHeight

                ColumnLayout {
                    anchors.fill: parent
                    anchors.rightMargin: 12
                    anchors.bottomMargin: 12
                    spacing: 4

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 130
                        radius: Theme.radiusMd
                        color: Theme.palette.color("muted", "#27272a")
                        clip: true

                        Image {
                            id: thumbnail

                            anchors.fill: parent
                            source: card.url
                            // A thumbnail, whatever the size of the file.
                            sourceSize: Qt.size(400, 400)
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            // A new address for the same bytes must not blank the picture.
                            retainWhileLoading: true
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: thumbnail.status === Image.Error
                            text: qsTr("Could not be shown")
                            color: browser.muted
                            font.pixelSize: Theme.type.meta.size
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 2

                        Text {
                            objectName: "spaceImageName"
                            Layout.fillWidth: true
                            text: card.name
                            elide: Text.ElideMiddle
                            color: browser.foreground
                            font.pixelSize: Theme.type.body.size
                        }

                        ShellButton {
                            objectName: "spaceImageTrash:" + card.name
                            visible: !browser.trashShown
                            subtle: true
                            iconName: "trash"
                            implicitHeight: 24
                            implicitWidth: 24
                            Accessible.name: qsTr("Move to the trash")
                            onClicked: Shell.dispatch("space.image.trash", { imageId: card.id })
                        }

                        ShellButton {
                            objectName: "spaceImageRestore:" + card.name
                            visible: browser.trashShown
                            subtle: true
                            iconName: "archive-restore"
                            implicitHeight: 24
                            implicitWidth: 24
                            Accessible.name: qsTr("Restore")
                            onClicked: Shell.dispatch("space.image.restore", { imageId: card.id })
                        }

                        ShellButton {
                            objectName: "spaceImageDelete:" + card.name
                            visible: browser.trashShown
                            subtle: true
                            iconName: "x"
                            implicitHeight: 24
                            implicitWidth: 24
                            tint: Theme.palette.color("error", "#ef4444")
                            Accessible.name: qsTr("Delete for good")
                            onClicked: Shell.dispatch("space.image.delete", { imageId: card.id })
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: card.prompt !== ""
                        text: card.prompt
                        elide: Text.ElideRight
                        color: browser.muted
                        font.pixelSize: Theme.type.meta.size
                    }

                    // Holds a card's top, with or without a prompt, level with the others.
                    Item {
                        Layout.fillHeight: true
                    }
                }
            }
        }
    }
}
