pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// The open page's comments (Spaces.comments) in a column beside it: open
// ones first, each resolved or reopened in place, and a new comment on the
// block `blockId` the user chose.
Rectangle {
    id: column

    objectName: "spaceComments"

    // The block a new comment goes on ("" when none is chosen).
    property string blockId: ""
    readonly property string blockText: {
        const row = Spaces.blocks.indexOf(column.blockId);
        return row < 0 ? "" : Spaces.blocks.get(row).text;
    }
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color lineColor: Theme.palette.color("border", "#27272a")
    property bool readOnly: false

    signal closeRequested

    function send() {
        const body = draft.text.trim();
        if (body.length === 0 || column.blockId === "")
            return;
        Shell.dispatch("space.comment.add", { pageId: Spaces.pageId, blockId: column.blockId, body: body });
        draft.clear();
    }

    function focusDraft() {
        draft.forceActiveFocus();
    }

    color: Theme.palette.color("surface", "#09090b")

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            // On the left: the toasts stack in the window's top right corner.
            ShellButton {
                objectName: "spaceCommentsClose"
                subtle: true
                iconName: "x"
                toolTip: qsTr("Hide comments")
                onClicked: column.closeRequested()
            }

            Text {
                Layout.fillWidth: true
                text: qsTr("Comments")
                color: column.foreground
                font.family: Theme.fontUi
                font.pixelSize: Math.round(14 * Theme.fontScale)
                font.weight: Font.DemiBold
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: column.blockId !== "" && column.blockText !== "" && !column.readOnly
            spacing: 6

            Text {
                Layout.fillWidth: true
                text: qsTr("On “%1”").arg(column.blockText)
                elide: Text.ElideRight
                color: column.muted
                font.family: Theme.fontUi
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }

            ShellTextField {
                id: draft

                objectName: "spaceCommentDraft"
                Layout.fillWidth: true
                font.family: Theme.fontUi
                placeholderText: qsTr("Add a comment")
                onAccepted: column.send()
            }

            ShellButton {
                objectName: "spaceCommentSend"
                Layout.alignment: Qt.AlignRight
                primary: true
                text: qsTr("Comment")
                enabled: draft.text.trim().length > 0
                onClicked: column.send()
            }
        }

        Text {
            Layout.fillWidth: true
            visible: Spaces.comments.count === 0
            wrapMode: Text.Wrap
            text: qsTr("No comments on this page yet. Choose a block's comment button to start one.")
            color: column.muted
            font.family: Theme.fontUi
            font.pixelSize: Math.round(13 * Theme.fontScale)
        }

        ListView {
            objectName: "spaceCommentList"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 8
            model: Spaces.comments
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
                id: comment

                required property var model
                required property string blockId
                required property string blockText
                required property string body
                required property bool resolved
                required property bool byAgent

                objectName: "spaceCommentRow:" + body
                width: ListView.view.width
                implicitHeight: content.implicitHeight + 16
                radius: Math.min(Theme.radius, 8)
                color: Theme.palette.color("surfaceRaised", "#18181b")
                border.color: comment.blockId === column.blockId ? Theme.palette.color("focus", "#3b82f6") : column.lineColor
                opacity: resolved ? 0.6 : 1

                ColumnLayout {
                    id: content

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 8
                    spacing: 4

                    Text {
                        Layout.fillWidth: true
                        text: "“" + comment.blockText + "”"
                        elide: Text.ElideRight
                        color: column.muted
                        font.family: Theme.fontUi
                        font.pixelSize: Math.round(11 * Theme.fontScale)

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: column.blockId = comment.blockId
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: comment.body
                        wrapMode: Text.Wrap
                        color: column.foreground
                        font.family: Theme.fontUi
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 4

                        Text {
                            Layout.fillWidth: true
                            text: (comment.byAgent ? qsTr("An agent") : qsTr("You")) + (comment.resolved ? qsTr(" · resolved") : "")
                            color: column.muted
                            font.family: Theme.fontUi
                            font.pixelSize: Math.round(11 * Theme.fontScale)
                        }

                        ShellButton {
                            objectName: (comment.resolved ? "spaceCommentReopen:" : "spaceCommentResolve:") + comment.body
                            subtle: true
                            iconName: comment.resolved ? "rotate-ccw" : "circle-check"
                            text: comment.resolved ? qsTr("Reopen") : qsTr("Resolve")
                            implicitHeight: 24
                            visible: !column.readOnly
                            onClicked: Shell.dispatch(comment.resolved ? "space.comment.reopen" : "space.comment.resolve", { commentId: comment.model.id })
                        }
                    }
                }
            }
        }
    }
}
