import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The environment this window is connected to, in Connections settings: how
// its connection stands (ConnectionHealthController's `connection`), with a
// retry and the failed attempt's trace id for a bug report.
RowLayout {
    id: row

    readonly property var model: Shell.state.connection ?? null

    objectName: "connectionStatusRow"
    spacing: 8

    Label {
        Layout.fillWidth: true
        text: qsTr("This machine's environment")
        color: Theme.palette.color("text", "#e4e4e7")
        font.pixelSize: Math.round(13 * Theme.fontScale)
        elide: Text.ElideRight
    }

    Label {
        objectName: "connectionStatus"
        text: row.model ? row.model.status : ""
        color: Theme.palette.color("textMuted", "#a1a1aa")
        font.pixelSize: Math.round(12 * Theme.fontScale)
    }

    ShellButton {
        subtle: true
        visible: row.model !== null && row.model.traceId.length > 0
        text: qsTr("Copy trace ID")
        onClicked: Shell.dispatch("connection.copyTraceId")
    }

    ShellButton {
        visible: row.model !== null && row.model.canRetry
        text: qsTr("Try again")
        onClicked: Shell.dispatch("connection.retry")
    }
}
