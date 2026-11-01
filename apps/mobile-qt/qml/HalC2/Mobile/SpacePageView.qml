pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The open page: its blocks, the way to add one, its comments and what can be
// done with it. A page in the trash is only read, and says so.
ColumnLayout {
    id: view

    required property Item screen
    readonly property var page: Spaces.page ?? ({})
    readonly property bool trashed: page.trashed === true
    readonly property var site: page.site ?? ({})
    readonly property string siteUrl: site.url ?? ""
    // The row being written in, kept above the keyboard.
    property SpaceBlockRow editing: null

    function keepEditingInView() {
        if (editing !== null)
            blocks.positionViewAtIndex(editing.index, ListView.Contain);
    }

    objectName: "spacePageView"
    spacing: 0

    MobileBar {
        Layout.fillWidth: true
        title: view.page.title ?? ""
        canGoBack: true
        onBackRequested: view.screen.backRequested()

        MobileIconButton {
            objectName: "spaceEditDone"
            visible: view.editing !== null
            iconName: "check"
            label: qsTr("Done")
            onClicked: view.screen.forceActiveFocus()
        }

        MobileIconButton {
            objectName: "spaceComments"
            iconName: "message-square"
            label: qsTr("Comments")
            onClicked: view.screen.showComments("")
        }

        MobileIconButton {
            objectName: "spacePageActions"
            iconName: "ellipsis"
            label: qsTr("Page actions")
            onClicked: view.trashed ? view.screen.trashMenu(Spaces.pageId) : view.screen.pageMenu(Spaces.pageId, view.page.title, view.page.parentPageId ?? "", view.site)
        }
    }

    ListView {
        id: blocks

        objectName: "spaceBlocks"
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        // A row that scrolls out while written in goes with what it holds, so
        // keep some around.
        cacheBuffer: 600
        model: Spaces.blocks
        onHeightChanged: Qt.callLater(view.keepEditingInView)

        header: ColumnLayout {
            width: ListView.view.width
            spacing: 0

            Label {
                objectName: "spacePageSource"
                Layout.fillWidth: true
                Layout.margins: 16
                Layout.bottomMargin: 4
                visible: (view.page.sourceThreadId ?? "") !== ""
                wrapMode: Text.Wrap
                text: qsTr("Made from the thread “%1”").arg(view.page.sourceThreadTitle ?? "")
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Math.round(13 * Theme.fontScale)
            }

            Label {
                objectName: "spaceTrashedNotice"
                Layout.fillWidth: true
                Layout.margins: 16
                Layout.bottomMargin: 4
                visible: view.trashed
                wrapMode: Text.Wrap
                text: qsTr("This page is in the trash. Restore it to edit it.")
                color: Theme.palette.color("error", "#ef4444")
                font.pixelSize: Math.round(13 * Theme.fontScale)
            }

            // The page's site: where it is, whether it is behind the page, and the ways on and back.
            ColumnLayout {
                objectName: "spaceSiteNotice"
                Layout.fillWidth: true
                Layout.margins: 16
                Layout.bottomMargin: 4
                visible: view.siteUrl !== ""
                spacing: 4

                Label {
                    objectName: "spaceSiteStatus"
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    text: view.site.behind === true
                        ? qsTr("Published. This page has changes the site does not show until you publish again.")
                        : qsTr("Published. The site shows this page as it is now.")
                    color: Theme.palette.color("text", "#e4e4e7")
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                }

                Label {
                    objectName: "spaceSiteLink"
                    Layout.fillWidth: true
                    elide: Text.ElideMiddle
                    text: view.siteUrl
                    color: Theme.palette.color("textMuted", "#a1a1aa")
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                }

                Label {
                    objectName: "spaceSiteLocalOnly"
                    Layout.fillWidth: true
                    visible: view.site.localOnly === true
                    wrapMode: Text.Wrap
                    text: qsTr("Only this machine can open this link: the MC listens on loopback.")
                    color: Theme.palette.color("textMuted", "#a1a1aa")
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: 4

                    MobileButton {
                        objectName: "spaceSiteCopy"
                        subtle: true
                        text: qsTr("Copy link")
                        onClicked: Shell.dispatch("space.page.copySiteLink", { pageId: Spaces.pageId })
                    }

                    MobileButton {
                        objectName: "spaceSiteRepublish"
                        subtle: true
                        text: qsTr("Publish again")
                        onClicked: Shell.dispatch("space.page.publish", { pageId: Spaces.pageId })
                    }

                    MobileButton {
                        objectName: "spaceSiteUnpublish"
                        subtle: true
                        text: qsTr("Unpublish")
                        onClicked: Shell.dispatch("space.page.unpublish", { pageId: Spaces.pageId })
                    }

                    MobileButton {
                        objectName: "spaceSiteTailscale"
                        visible: view.site.localOnly === true
                        subtle: true
                        text: qsTr("Publish over Tailscale")
                        onClicked: Shell.dispatch("space.page.publish", { pageId: Spaces.pageId, tailscale: true })
                    }
                }
            }
        }

        delegate: SpaceBlockRow {
            id: blockRow

            width: ListView.view.width
            readOnly: view.trashed
            onScreen: view.visible
            onEditingChanged: {
                if (editing) {
                    view.editing = blockRow;
                    Qt.callLater(view.keepEditingInView);
                } else if (view.editing === blockRow) {
                    view.editing = null;
                }
            }
            onMenuRequested: view.screen.blockMenu(blockRow.index, blockRow.blockId, blockRow.text)
            onLinkOpened: view.screen.openPage(blockRow.linkedPageId)
            onCommentsRequested: view.screen.showComments(blockRow.blockId)
        }

        footer: ColumnLayout {
            width: ListView.view.width
            spacing: 0

            Label {
                objectName: "spacePageEmpty"
                Layout.fillWidth: true
                Layout.margins: 24
                visible: Spaces.blocks.count === 0
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: qsTr("This page is empty.")
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Math.round(14 * Theme.fontScale)
            }

            MobileButton {
                objectName: "spaceAddBlock"
                Layout.alignment: Qt.AlignLeft
                Layout.margins: 12
                visible: !view.trashed
                subtle: true
                text: qsTr("Add block")
                onClicked: view.screen.addBlockMenu(undefined)
            }
        }
    }
}
