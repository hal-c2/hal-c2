import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// What the open thread's provider says when it cannot run a turn
// (Shell.state.providerNotice, ProviderNoticeController): signed out, not
// installed, unavailable, or a version known to break turns. Provider setup
// opens from it when it can install or sign the provider in; dismissing hides
// that problem until it changes.
Rectangle {
    id: banner

    readonly property var current: Shell.state.providerNotice ?? null
    readonly property color tone: current?.warning === true ? Theme.palette.color("warning", "#f59e0b") : Theme.palette.color("error", "#ef4444")
    // One notice at a time above the composer (Shell.state.noticeStack,
    // NoticeStackController); no stack published means drawn on its own.
    readonly property var stack: Shell.state.noticeStack ?? null
    readonly property bool inFront: stack === null || stack.expanded === true || stack.front === "provider"

    objectName: "providerNotice"
    visible: current !== null && inFront
    implicitHeight: visible ? row.implicitHeight + 16 : 0
    // Opaque: it lies over the conversation.
    color: Qt.tint(Theme.palette.color("surface", "#0f0f11"), Qt.alpha(tone, 0.12))

    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 3
        color: banner.tone
    }

    RowLayout {
        id: row

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 8
        anchors.leftMargin: 16
        anchors.rightMargin: 8
        spacing: 8

        ShellIcon {
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: 2
            name: "info"
            size: 14
            color: banner.tone
        }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Label {
                objectName: "providerNoticeTitle"
                Layout.fillWidth: true
                text: banner.current?.title ?? ""
                color: Theme.palette.color("text", "#e4e4e7")
                font.pixelSize: Theme.type.body.size
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }
            Label {
                objectName: "providerNoticeMessage"
                Layout.fillWidth: true
                text: banner.current?.message ?? ""
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Theme.type.body.size
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
            }
        }
        ShellButton {
            objectName: "providerNoticeSetup"
            Layout.alignment: Qt.AlignTop
            visible: banner.current?.setup === true
            subtle: true
            text: qsTr("Open provider setup")
            onClicked: Shell.dispatch("providerNotice.setup", {})
        }
        ShellButton {
            objectName: "providerNoticeDismiss"
            Layout.alignment: Qt.AlignTop
            subtle: true
            iconName: "x"
            Accessible.name: qsTr("Dismiss provider notice")
            onClicked: Shell.dispatch("providerNotice.dismiss", {})
        }
    }
}
