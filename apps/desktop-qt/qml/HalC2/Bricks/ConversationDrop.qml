import QtQuick
import HalC2.Shell

// Lay this over the conversation (the timeline and the composer under it):
// files dragged anywhere on it are attached to `composer`'s draft and
// folders referenced in it, as `composer.attach` takes them. While a drag
// of files is over it, it says so; a drag of anything else (selected text,
// a web link) passes it by.
DropArea {
    id: root

    // The Composer the drop goes to.
    required property Item composer

    keys: ["text/uri-list"]
    onEntered: drag => {
        drag.accepted = drag.hasUrls && drag.urls.some(url => String(url).startsWith("file:"));
    }
    onDropped: drop => {
        if (drop.hasUrls) {
            root.composer.attach(drop.urls);
            drop.accept(Qt.CopyAction);
        }
    }

    Rectangle {
        objectName: "conversationDropHint"
        anchors.fill: parent
        anchors.margins: 8
        visible: root.containsDrag
        radius: 16
        color: Qt.alpha(Theme.palette.color("accent", "#3b82f6"), 0.035)
        border.color: Qt.alpha(Theme.palette.color("accent", "#3b82f6"), 0.6)
        border.width: 2

        Rectangle {
            anchors.centerIn: parent
            width: hintRow.implicitWidth + 32
            height: hintRow.implicitHeight + 20
            radius: height / 2
            color: Qt.alpha(Theme.palette.color("canvas", "#0f0f12"), 0.95)
            border.color: Qt.alpha(Theme.palette.color("accent", "#3b82f6"), 0.25)
            border.width: 1

            Row {
                id: hintRow

                anchors.centerIn: parent
                spacing: 8

                ShellIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "paperclip"
                    size: 16
                    color: Theme.palette.color("accent", "#3b82f6")
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Drop files to attach")
                    color: Theme.palette.color("text", "#e4e4e7")
                    font.pixelSize: Math.round(14 * Theme.fontScale)
                    font.weight: Font.Medium
                    Accessible.role: Accessible.StatusBar
                }
            }
        }
    }
}
