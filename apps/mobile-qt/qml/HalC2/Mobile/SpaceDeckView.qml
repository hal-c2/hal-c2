pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The open deck: its slides, the way to add one, the way to present it and what
// can be done with it. A deck in the trash is only read, and says so.
ColumnLayout {
    id: view

    required property Item screen
    readonly property var deck: Spaces.deck ?? ({})
    readonly property bool trashed: deck.trashed === true
    // The row being written in, kept above the keyboard.
    property SpaceSlideRow editing: null

    function keepEditingInView() {
        if (editing !== null)
            slides.positionViewAtIndex(editing.index, ListView.Contain);
    }

    objectName: "spaceDeckView"
    spacing: 0

    MobileBar {
        Layout.fillWidth: true
        title: view.deck.title ?? ""
        canGoBack: true
        onBackRequested: view.screen.backRequested()

        MobileIconButton {
            objectName: "spaceDeckDone"
            visible: view.editing !== null
            iconName: "check"
            label: qsTr("Done")
            onClicked: view.screen.forceActiveFocus()
        }

        // With no slides it still answers, by saying why nothing shows.
        MobileIconButton {
            objectName: "spaceDeckPresent"
            visible: !view.trashed
            iconName: "play"
            label: qsTr("Present")
            onClicked: view.screen.present(Spaces.deckId)
        }

        MobileIconButton {
            objectName: "spaceDeckActions"
            iconName: "ellipsis"
            label: qsTr("Deck actions")
            onClicked: view.trashed ? view.screen.deckTrashMenu(Spaces.deckId) : view.screen.deckMenu(Spaces.deckId, view.deck.title)
        }
    }

    ListView {
        id: slides

        objectName: "spaceSlides"
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        // A row that scrolls out while written in goes with what it holds, so
        // keep some around.
        cacheBuffer: 600
        model: Spaces.slides
        onHeightChanged: Qt.callLater(view.keepEditingInView)

        header: ColumnLayout {
            width: ListView.view.width
            spacing: 0

            Label {
                objectName: "spaceDeckTrashedNotice"
                Layout.fillWidth: true
                Layout.margins: 16
                visible: view.trashed
                wrapMode: Text.Wrap
                text: qsTr("This deck is in the trash. Restore it to edit it.")
                color: Theme.palette.color("error", "#ef4444")
                font.pixelSize: Math.round(13 * Theme.fontScale)
            }
        }

        delegate: SpaceSlideRow {
            id: slideRow

            width: ListView.view.width
            readOnly: view.trashed
            onEditingChanged: {
                if (editing) {
                    view.editing = slideRow;
                    Qt.callLater(view.keepEditingInView);
                } else if (view.editing === slideRow) {
                    view.editing = null;
                }
            }
            onMenuRequested: view.screen.slideMenu(slideRow.index, slideRow.slideId)
        }

        footer: ColumnLayout {
            width: ListView.view.width
            spacing: 0

            Label {
                objectName: "spaceDeckEmpty"
                Layout.fillWidth: true
                Layout.margins: 24
                visible: Spaces.slides.count === 0
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: qsTr("This deck has no slides.")
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Math.round(14 * Theme.fontScale)
            }

            MobileButton {
                objectName: "spaceAddSlide"
                Layout.alignment: Qt.AlignLeft
                Layout.margins: 12
                visible: !view.trashed
                subtle: true
                text: qsTr("Add slide")
                onClicked: view.screen.askNewSlide(undefined)
            }
        }
    }
}
