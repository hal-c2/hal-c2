pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → Review sandboxes: whether this environment can run code reviews
// in an OpenShell sandbox and, when it can't, what is wrong and what to do, as
// SandboxSettingsController publishes it (features/mc/platform/openshell.feature).
SettingsPage {
    id: sandboxes

    readonly property var status: Shell.state.sandboxSettings ?? null
    readonly property string kind: status?.state ?? "loading"
    readonly property color muted: Theme.palette.color("inkTertiary", "#a1a1aa")

    objectName: "sandboxSettings"
    title: qsTr("Review sandboxes")

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.space.md

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.space.xxs

            Label {
                objectName: "sandboxSummary"
                Layout.fillWidth: true
                text: sandboxes.status?.summary ?? ""
                color: sandboxes.kind === "error" ? Theme.palette.color("errorForeground", "#ef4444")
                     : sandboxes.kind === "ready" || sandboxes.kind === "loading" ? Theme.palette.color("ink", "#e4e4e7")
                     : Theme.palette.color("warningForeground", "#fbbf24")
                font.pixelSize: Theme.type.body.size
                font.weight: Font.Medium
                wrapMode: Text.Wrap
            }

            Label {
                objectName: "sandboxDetail"
                Layout.fillWidth: true
                visible: text.length > 0
                text: sandboxes.status?.error ?? sandboxes.status?.detail ?? ""
                color: sandboxes.muted
                font.pixelSize: Theme.type.meta.size
                wrapMode: Text.Wrap
            }
        }

        ShellButton {
            objectName: "sandboxRefresh"
            Layout.alignment: Qt.AlignTop
            text: sandboxes.status?.loading ? qsTr("Checking…") : qsTr("Refresh")
            iconName: "refresh-cw"
            enabled: !(sandboxes.status?.loading ?? true)
            onClicked: Shell.dispatch("sandboxSettings.refresh")
        }
    }

    Repeater {
        model: sandboxes.status?.problems ?? []

        Label {
            required property var modelData

            objectName: "sandboxProblem:" + modelData.code
            Layout.fillWidth: true
            text: modelData.message
            color: Theme.palette.color("ink", "#e4e4e7")
            font.pixelSize: Theme.type.meta.size
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
        }
    }
}
