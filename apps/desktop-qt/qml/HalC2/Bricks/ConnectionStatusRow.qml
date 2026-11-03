import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Under "This machine" in Connections settings: how the window's connection to
// its environment stands (ConnectionHealthController's `connection`) as an
// icon and a word, its sentence on hover, with a retry and the failed
// attempt's trace id for a bug report. A reconnect still settling reads as
// connected, as the window's notice does.
RowLayout {
    id: row

    readonly property var model: Shell.state.connection ?? null
    readonly property string shown: model === null ? "" : model.settling ? "ready" : model.state

    objectName: "connectionStatusRow"
    spacing: 8

    Label {
        Layout.fillWidth: true
        text: qsTr("Connection")
        color: Theme.palette.color("text", "#e4e4e7")
        font.pixelSize: Math.round(13 * Theme.fontScale)
        elide: Text.ElideRight
    }

    ShellIcon {
        name: ({
                connecting: "circle-dashed",
                ready: "circle-check",
                retrying: "refresh-cw",
                offline: "cloud",
                needsPairing: "lock",
                blocked: "octagon-alert"
            })[row.shown] ?? "circle-dashed"
        size: Math.round(14 * Theme.fontScale)
        color: row.shown === "ready" ? Theme.palette.color("success", "#22c55e") : row.shown === "retrying" ? Theme.palette.color("warning", "#f59e0b") : row.shown === "needsPairing" || row.shown === "blocked" ? Theme.palette.color("error", "#ef4444") : Theme.palette.color("textMuted", "#a1a1aa")
    }

    Label {
        objectName: "connectionStatus"
        text: row.model === null ? "" : row.model.settling ? qsTr("Connected") : row.model.status
        color: Theme.palette.color("textMuted", "#a1a1aa")
        font.pixelSize: Math.round(12 * Theme.fontScale)

        HoverHandler {
            id: statusHover
        }

        ToolTip.visible: statusHover.hovered && row.model !== null && !row.model.settling && row.model.title.length > 0
        ToolTip.delay: 300
        ToolTip.text: row.model ? row.model.title + (row.model.detail.length > 0 ? "\n" + row.model.detail : "") : ""
    }

    ShellButton {
        subtle: true
        visible: row.model !== null && !row.model.settling && row.model.traceId.length > 0
        text: qsTr("Copy trace ID")
        onClicked: Shell.dispatch("connection.copyTraceId")
    }

    ShellButton {
        visible: row.model !== null && !row.model.settling && row.model.canRetry
        text: qsTr("Try again")
        onClicked: Shell.dispatch("connection.retry")
    }
}
