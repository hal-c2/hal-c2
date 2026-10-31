pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The pages of the open Space as a tree, its trash under them.
ColumnLayout {
    id: view

    required property Item screen
    // Why there is nothing to list.
    readonly property string emptyText: {
        if (Spaces.status === "unreachable")
            return qsTr("The MC cannot be reached, so its Spaces cannot be shown.");
        if (Spaces.status === "loading")
            return qsTr("Loading the Space…");
        return qsTr("%1 has no pages yet.").arg(Spaces.spaceName);
    }

    objectName: "spacePagesView"
    spacing: 0

    MobileBar {
        Layout.fillWidth: true
        title: Spaces.spaceName
        canGoBack: true
        onBackRequested: view.screen.backRequested()

        MobileIconButton {
            objectName: "spaceImport"
            iconName: "download"
            label: qsTr("Import Markdown")
            onClicked: view.screen.askImport()
        }

        MobileIconButton {
            objectName: "spaceNewPage"
            iconName: "plus"
            label: qsTr("New page")
            onClicked: view.screen.askNewPage("")
        }
    }

    ListView {
        objectName: "spacePages"
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: Spaces.pages

        delegate: SpaceListRow {
            required property var model
            required property string parentPageId

            objectName: "spacePage:" + title
            width: ListView.view.width
            title: model.title
            depth: model.depth
            iconName: model.fromThread ? "message-square" : "file-text"
            menuName: "spacePageMenu:" + model.title
            onClicked: view.screen.openPage(model.id)
            onMenuRequested: view.screen.pageMenu(model.id, model.title, parentPageId)
        }

        footer: ColumnLayout {
            width: ListView.view.width
            spacing: 0

            Label {
                objectName: "spaceEmptyText"
                Layout.fillWidth: true
                Layout.margins: 24
                visible: Spaces.pages.count === 0
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Math.round(14 * Theme.fontScale)
                text: view.emptyText
            }

            Label {
                objectName: "spaceTrash"
                Layout.fillWidth: true
                Layout.leftMargin: 16
                Layout.topMargin: 16
                Layout.bottomMargin: 4
                visible: Spaces.trash.count > 0
                text: qsTr("Trash")
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.DemiBold
            }

            Repeater {
                model: Spaces.trash

                delegate: SpaceListRow {
                    id: trashed

                    required property var model

                    objectName: "spaceTrashRow:" + title
                    Layout.fillWidth: true
                    title: model.title
                    iconName: "trash"
                    menuName: "spaceTrashMenu:" + model.title
                    onClicked: view.screen.openPage(model.id)
                    onMenuRequested: view.screen.trashMenu(model.id)
                }
            }
        }
    }
}
