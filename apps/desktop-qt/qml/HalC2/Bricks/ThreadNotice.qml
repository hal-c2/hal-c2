import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// What the open thread says under its conversation (Shell.state.threadNotice,
// ThreadNoticeController): work its finished turn left running in the
// background, which stops from here, or that it is settled, which un-settles.
Rectangle {
    id: notice

    readonly property var current: Shell.state.threadNotice ?? null
    readonly property bool background: current?.kind === "background"
    readonly property color info: Theme.palette.color("info", "#3b82f6")

    objectName: "threadNotice"
    visible: current !== null
    implicitHeight: visible ? row.implicitHeight + 16 : 0
    color: Qt.alpha(info, 0.1)

    RowLayout {
        id: row

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 8
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        spacing: 8

        ShellIcon {
            name: notice.background ? "circle-dashed" : "circle-check"
            size: 14
            color: notice.info
        }
        Label {
            objectName: "threadNoticeTitle"
            text: notice.current?.title ?? ""
            color: notice.info
            font.pixelSize: Theme.type.body.size
            font.weight: Font.Medium
        }
        Label {
            objectName: "threadNoticeDescription"
            Layout.fillWidth: true
            text: notice.current?.description ?? ""
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Theme.type.meta.size
            maximumLineCount: 1
            elide: Text.ElideRight
        }
        ShellButton {
            objectName: "threadNoticeAction"
            subtle: true
            enabled: notice.current?.busy !== true
            text: notice.current?.actionLabel ?? ""
            onClicked: Shell.dispatch(notice.background ? "threadNotice.stop" : "threadNotice.unsettle", {})
        }
    }
}
