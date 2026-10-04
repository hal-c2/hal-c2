import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// What the window says while its connection to the environment is not live
// (ConnectionHealthController publishes `connection`): reconnecting and why,
// waiting for the network, a credential to pair again, a side to update, or
// a server behind this app.
Rectangle {
    id: notice

    readonly property var model: Shell.state.connection ?? null
    readonly property var warning: model ? model.versionWarning : null
    readonly property bool troubled: model !== null && model.title.length > 0

    objectName: "connectionNotice"
    visible: troubled || warning !== null
    anchors.horizontalCenter: parent.horizontalCenter
    y: 12
    width: Math.min(parent.width - 32, 520)
    height: content.implicitHeight + 24
    radius: 8
    color: Theme.palette.color("surfaceOverlay", "#18181b")
    border.color: Theme.palette.color(troubled ? "warning" : "border", troubled ? "#f59e0b" : "#27272a")
    border.width: 1

    ColumnLayout {
        id: content

        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        Label {
            objectName: "connectionNoticeTitle"
            Layout.fillWidth: true
            visible: notice.troubled
            text: notice.model ? notice.model.title : ""
            font.bold: true
            font.pixelSize: Math.round(13 * Theme.fontScale)
            color: Theme.palette.color("text", "#e4e4e7")
            wrapMode: Text.Wrap
        }

        Label {
            objectName: "connectionNoticeDetail"
            Layout.fillWidth: true
            text: notice.troubled ? notice.model.detail : notice.warning ? notice.warning.text : ""
            font.pixelSize: Math.round(12 * Theme.fontScale)
            color: Theme.palette.color("textMuted", "#a1a1aa")
            wrapMode: Text.Wrap
        }

        RowLayout {
            Layout.fillWidth: true
            visible: notice.model !== null && notice.model.needsPairing
            spacing: 8

            ShellTextField {
                id: link

                objectName: "connectionPairingLink"
                Layout.fillWidth: true
                placeholderText: qsTr("Pairing link")
                Accessible.name: qsTr("Pairing link")
                onAccepted: pair.clicked()
            }

            ShellButton {
                id: pair

                objectName: "connectionPair"
                primary: true
                text: qsTr("Pair again")
                enabled: link.text.trim().length > 0 && !notice.model.pairing
                onClicked: Shell.dispatch("connection.pair", {
                    pairingUrl: link.text
                })
            }
        }

        Label {
            Layout.fillWidth: true
            visible: text.length > 0
            text: notice.model ? notice.model.pairingError : ""
            font.pixelSize: Math.round(12 * Theme.fontScale)
            color: Theme.palette.color("error", "#f87171")
            wrapMode: Text.Wrap
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Item {
                Layout.fillWidth: true
            }

            ShellButton {
                objectName: "connectionCopyTraceId"
                subtle: true
                visible: notice.troubled && notice.model.traceId.length > 0
                text: qsTr("Copy trace ID")
                onClicked: Shell.dispatch("connection.copyTraceId")
            }

            ShellButton {
                objectName: "connectionRetry"
                visible: notice.troubled && notice.model.canRetry
                text: qsTr("Try again")
                onClicked: Shell.dispatch("connection.retry")
            }

            ShellButton {
                objectName: "connectionDismissWarning"
                subtle: true
                visible: !notice.troubled && notice.warning !== null
                text: qsTr("Dismiss")
                onClicked: Shell.dispatch("connection.dismissVersionWarning")
            }
        }
    }
}
