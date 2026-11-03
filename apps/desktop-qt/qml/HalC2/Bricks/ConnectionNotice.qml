import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The window's connection to its environment while it is not live
// (ConnectionHealthController publishes `connection`), as an icon and a word:
// connecting, reconnecting, offline, needs pairing, or blocked, or a server
// behind this app. Hovering says what is going on; clicking opens a panel
// with a sentence on it and what the user can do. A reconnect still settling
// shows nothing. Children go in the panel's row of actions.
Item {
    id: notice

    readonly property var model: Shell.state.connection ?? null
    readonly property var warning: model ? model.versionWarning : null
    readonly property bool troubled: model !== null && model.phase !== "connected" && model.title.length > 0 && !model.settling
    // Whether the panel is open: the user clicked the icon.
    property bool open: false
    default property alias actions: extra.data
    // What hovering the icon says.
    readonly property string tip: troubled ? model.title + (model.detail.length > 0 ? "\n" + model.detail : "") : warning ? warning.text : ""

    readonly property string icon: {
        if (!troubled)
            return "circle-arrow-up";
        switch (model.state) {
        case "connecting":
            return "circle-dashed";
        case "retrying":
            return "refresh-cw";
        case "offline":
            return "cloud";
        case "needsPairing":
            return "lock";
        default:
            return "octagon-alert";
        }
    }
    readonly property color tint: !troubled || model.state === "connecting" || model.state === "offline" ? Theme.palette.color("textMuted", "#a1a1aa") : model.state === "retrying" ? Theme.palette.color("warning", "#f59e0b") : Theme.palette.color("error", "#ef4444")

    objectName: "connectionNotice"
    visible: troubled || warning !== null
    onVisibleChanged: if (!visible)
        open = false
    anchors.horizontalCenter: parent.horizontalCenter
    y: 12
    width: open ? Math.min(parent.width - 32, 520) : chip.implicitWidth
    height: open ? chip.height + 8 + panel.height : chip.height

    // The icon and its word.
    AbstractButton {
        id: chip

        objectName: "connectionNoticeButton"
        anchors.horizontalCenter: parent.horizontalCenter
        implicitWidth: chipRow.implicitWidth + 20
        implicitHeight: chipRow.implicitHeight + 10
        hoverEnabled: true
        Accessible.name: notice.tip
        onClicked: notice.open = !notice.open

        ToolTip.visible: hovered && !notice.open
        ToolTip.delay: 300
        ToolTip.text: notice.tip

        background: Rectangle {
            radius: height / 2
            color: Theme.palette.color("surfaceOverlay", "#18181b")
            border.color: chip.hovered || notice.open ? notice.tint : Theme.palette.color("border", "#27272a")
            border.width: 1
        }

        contentItem: Item {
            RowLayout {
                id: chipRow

                anchors.centerIn: parent
                spacing: 6

                ShellIcon {
                    objectName: "connectionNoticeIcon"
                    name: notice.icon
                    size: Math.round(14 * Theme.fontScale)
                    color: notice.tint
                }

                Label {
                    objectName: "connectionNoticeStatus"
                    text: notice.troubled ? notice.model.status : qsTr("Server behind")
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    color: Theme.palette.color("text", "#e4e4e7")
                }
            }
        }
    }

    Rectangle {
        id: panel

        anchors.top: chip.bottom
        anchors.topMargin: 8
        width: parent.width
        height: content.implicitHeight + 24
        visible: notice.open
        radius: 8
        color: Theme.palette.color("surfaceOverlay", "#18181b")
        border.color: Theme.palette.color(notice.troubled ? "warning" : "border", notice.troubled ? "#f59e0b" : "#27272a")
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
                visible: text.length > 0
                text: notice.troubled ? notice.model.detail : notice.warning ? notice.warning.text : ""
                font.pixelSize: Math.round(12 * Theme.fontScale)
                color: Theme.palette.color("textMuted", "#a1a1aa")
                wrapMode: Text.Wrap
            }

            ServerUpdateAction {
                Layout.fillWidth: true
                visible: offered && !notice.troubled && notice.warning !== null
                environmentId: notice.warning ? (notice.warning.environmentId ?? "") : ""
                label: qsTr("Update server")
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
                color: Theme.palette.color("errorForeground", "#f87171")
                wrapMode: Text.Wrap
            }

            RowLayout {
                id: extra

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
}
