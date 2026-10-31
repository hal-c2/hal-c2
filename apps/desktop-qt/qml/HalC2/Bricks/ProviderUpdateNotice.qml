import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The bottom of the sidebar while a provider update runs or just finished
// (Shell.state.providerUpdates.notice, ProviderUpdateNotice): what it is,
// opening the Providers settings when chosen, and a dismiss for what stays.
Rectangle {
    id: notice

    readonly property var current: Shell.state.providerUpdates?.notice ?? null
    readonly property color tone: {
        switch (current?.tone) {
        case "error":
            return Theme.palette.color("error", "#ef4444");
        case "warning":
            return Theme.palette.color("warning", "#e0af68");
        case "success":
            return Theme.palette.color("update", "#22c55e");
        default:
            return Theme.palette.color("textMuted", "#8b8b93");
        }
    }

    objectName: "providerUpdateNotice"
    visible: current !== null
    implicitHeight: visible ? row.implicitHeight + 12 : 0
    radius: 6
    color: area.containsMouse ? Qt.alpha(tone, 0.16) : Qt.alpha(tone, 0.1)
    Accessible.role: Accessible.Button
    Accessible.name: current?.title ?? ""
    Accessible.description: current?.description ?? ""

    MouseArea {
        id: area

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: Shell.dispatch("providerUpdates.openNotice", {})
    }

    RowLayout {
        id: row

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 8
        anchors.rightMargin: 4
        spacing: 8

        // A still icon while it runs: a spinner would repaint every frame.
        ShellIcon {
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: 1
            name: notice.current?.tone === "loading" ? "refresh-cw" : notice.current?.tone === "success" ? "circle-check" : notice.current?.tone === "error" ? "circle-x" : "triangle-alert"
            size: 14
            color: notice.tone
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Label {
                objectName: "providerUpdateNoticeTitle"
                Layout.fillWidth: true
                text: notice.current?.title ?? ""
                color: Theme.palette.color("text", "#e4e4e7")
                font.pixelSize: Math.round(12 * Theme.fontScale)
                font.weight: Font.Medium
                elide: Text.ElideRight
            }
            Label {
                Layout.fillWidth: true
                visible: text.length > 0
                text: notice.current?.description ?? ""
                color: Theme.palette.color("textMuted", "#8b8b93")
                font.pixelSize: Math.round(11 * Theme.fontScale)
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }
        }

        ShellButton {
            objectName: "providerUpdateNoticeDismiss"
            Layout.alignment: Qt.AlignTop
            visible: notice.current?.dismissible === true
            subtle: true
            implicitWidth: 22
            implicitHeight: 22
            leftPadding: 0
            rightPadding: 0
            text: "✕"
            tint: Theme.palette.color("textMuted", "#8b8b93")
            font.pixelSize: Math.round(10 * Theme.fontScale)
            Accessible.name: qsTr("Dismiss")
            onClicked: Shell.dispatch("providerUpdates.dismissNotice", {})
        }
    }
}
