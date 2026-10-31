pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The open page's comments, resolved ones too, each with the block it is on and
// the way to resolve or reopen it.
ColumnLayout {
    id: view

    required property Item screen

    // Brings the first comment on `blockId` into view.
    function showBlock(blockId) {
        for (let row = 0; row < Spaces.comments.count; ++row) {
            if (Spaces.comments.get(row).blockId === blockId) {
                list.positionViewAtIndex(row, ListView.Beginning);
                return;
            }
        }
    }

    objectName: "spaceCommentsView"
    spacing: 0

    MobileBar {
        Layout.fillWidth: true
        title: qsTr("Comments")
        canGoBack: true
        onBackRequested: view.screen.backRequested()

        MobileIconButton {
            objectName: "spaceCommentAdd"
            visible: (Spaces.page ?? {}).trashed !== true
            iconName: "message-square-plus"
            label: qsTr("Comment on the page")
            onClicked: view.screen.askComment("")
        }
    }

    ListView {
        id: list

        objectName: "spaceCommentList"
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: Spaces.comments

        delegate: ColumnLayout {
            id: comment

            required property var model
            required property string blockText
            required property string body
            required property bool resolved
            required property bool byAgent

            objectName: "spaceCommentRow:" + body
            width: ListView.view.width
            spacing: 2
            opacity: resolved ? 0.6 : 1

            Label {
                Layout.fillWidth: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.topMargin: 10
                visible: comment.blockText !== ""
                text: comment.blockText
                elide: Text.ElideRight
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }

            Label {
                Layout.fillWidth: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.topMargin: comment.blockText !== "" ? 0 : 10
                text: comment.body
                wrapMode: Text.Wrap
                font.pixelSize: Math.round(15 * Theme.fontScale)
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 16
                Layout.rightMargin: 4
                spacing: 8

                Label {
                    Layout.fillWidth: true
                    text: comment.resolved ? qsTr("Resolved") : comment.byAgent ? qsTr("agent") : ""
                    color: Theme.palette.color("textMuted", "#a1a1aa")
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }

                MobileButton {
                    objectName: (comment.resolved ? "spaceCommentReopen:" : "spaceCommentResolve:") + comment.body
                    visible: (Spaces.page ?? {}).trashed !== true
                    subtle: true
                    text: comment.resolved ? qsTr("Reopen") : qsTr("Resolve")
                    onClicked: Shell.dispatch(comment.resolved ? "space.comment.reopen" : "space.comment.resolve", { commentId: comment.model.id })
                }
            }
        }

        footer: Label {
            objectName: "spaceCommentsEmpty"
            width: ListView.view.width
            padding: 24
            visible: Spaces.comments.count === 0
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: qsTr("No comments yet.")
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Math.round(14 * Theme.fontScale)
        }
    }
}
