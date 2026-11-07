import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The open thread's error over the top of its conversation
// (Shell.state.threadError, ThreadErrorController); a usage limit is a
// warning. Dismissing hides that error on the thread; a different one shows.
Rectangle {
    id: banner

    readonly property var current: Shell.state.threadError ?? null
    readonly property color tone: current?.warning === true ? Theme.palette.color("warning", "#f59e0b") : Theme.palette.color("error", "#ef4444")

    objectName: "threadError"
    visible: current !== null
    implicitHeight: visible ? row.implicitHeight + 16 : 0
    // Opaque: it lies over the conversation.
    color: Qt.tint(Theme.palette.color("surface", "#0f0f11"), Qt.alpha(tone, 0.12))

    // The tone is the stripe; the sentence is the theme's text, which reads
    // on the tint in a light theme too.
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
            name: banner.current?.warning === true ? "triangle-alert" : "circle-alert"
            size: 14
            color: banner.tone
        }
        Label {
            objectName: "threadErrorMessage"
            Layout.fillWidth: true
            text: banner.current?.message ?? ""
            color: Theme.palette.color("text", "#e4e4e7")
            font.pixelSize: Theme.type.body.size
            wrapMode: Text.Wrap
            maximumLineCount: 4
            elide: Text.ElideRight
        }
        ShellButton {
            objectName: "threadErrorDismiss"
            Layout.alignment: Qt.AlignTop
            subtle: true
            iconName: "x"
            Accessible.name: qsTr("Dismiss error")
            onClicked: Shell.dispatch("threadError.dismiss", {})
        }
    }
}
