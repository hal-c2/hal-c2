pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → Review sandboxes: whether this environment can run code reviews
// in an OpenShell sandbox and, when it can't, what is wrong and what to do, as
// SandboxSettingsController publishes it (features/mc/platform/openshell.feature),
// with the operations the MC offers (Install, Check, Rotate certificates,
// Uninstall, …), the one running and how the last one went.
SettingsPage {
    id: sandboxes

    readonly property var status: Shell.state.sandboxSettings ?? null
    readonly property string kind: status?.state ?? "loading"
    readonly property color muted: Theme.palette.color("inkTertiary", "#a1a1aa")
    readonly property color errorColor: Theme.palette.color("errorForeground", "#ef4444")
    readonly property var operation: status?.operation ?? null
    readonly property bool canRun: (status?.canManage ?? false) && !(status?.busy ?? false)

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

    // The operation running, or the last one run, and how it went.
    ColumnLayout {
        objectName: "sandboxOperation"
        Layout.fillWidth: true
        visible: sandboxes.operation !== null || (sandboxes.status?.refusal ?? null) !== null
        spacing: Theme.space.xxs

        Label {
            objectName: "sandboxProgress"
            Layout.fillWidth: true
            visible: sandboxes.operation?.running ?? false
            text: sandboxes.operation?.label ?? ""
            color: Theme.palette.color("accent", "#60a5fa")
            font.pixelSize: Theme.type.meta.size
            font.weight: Font.Medium
            wrapMode: Text.Wrap
        }

        Repeater {
            model: sandboxes.operation?.steps ?? []

            Label {
                required property string modelData
                required property int index

                objectName: "sandboxStep:" + index
                Layout.fillWidth: true
                Layout.leftMargin: Theme.space.md
                text: modelData
                color: sandboxes.muted
                font.pixelSize: Theme.type.meta.size
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
            }
        }

        Label {
            objectName: "sandboxResult"
            Layout.fillWidth: true
            // A question about the outcome says it already.
            visible: (sandboxes.operation?.result ?? null) !== null && (sandboxes.status?.confirm ?? null) === null
            text: sandboxes.operation?.result?.message ?? ""
            color: sandboxes.operation?.result?.ok ? Theme.palette.color("success", "#22c55e") : sandboxes.errorColor
            font.pixelSize: Theme.type.meta.size
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
        }

        Label {
            objectName: "sandboxRefusal"
            Layout.fillWidth: true
            visible: text.length > 0
            text: sandboxes.status?.refusal ?? ""
            color: sandboxes.errorColor
            font.pixelSize: Theme.type.meta.size
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
        }
    }

    // Before an operation stops this MC's reviews.
    Rectangle {
        objectName: "sandboxConfirm"
        Layout.fillWidth: true
        visible: (sandboxes.status?.confirm ?? null) !== null
        implicitHeight: confirmColumn.implicitHeight + 2 * Theme.space.md
        radius: Theme.radiusMd
        color: "transparent"
        border.color: Theme.palette.color("warning", "#f59e0b")
        border.width: 1

        ColumnLayout {
            id: confirmColumn

            anchors.fill: parent
            anchors.margins: Theme.space.md
            spacing: Theme.space.sm

            Label {
                objectName: "sandboxConfirmText"
                Layout.fillWidth: true
                text: sandboxes.status?.confirm?.text ?? ""
                color: Theme.palette.color("ink", "#e4e4e7")
                font.pixelSize: Theme.type.body.size
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
            }

            RowLayout {
                spacing: Theme.space.sm

                ShellButton {
                    objectName: "sandboxConfirmYes"
                    primary: true
                    text: qsTr("Go ahead")
                    onClicked: Shell.dispatch("sandboxSettings.confirm")
                }

                ShellButton {
                    objectName: "sandboxConfirmCancel"
                    text: qsTr("Cancel")
                    onClicked: Shell.dispatch("sandboxSettings.cancel")
                }
            }
        }
    }

    // What the MC offers to do about OpenShell; off, with why, when this
    // device may not, and while an operation runs.
    Flow {
        objectName: "sandboxActions"
        Layout.fillWidth: true
        visible: (sandboxes.status?.actions ?? []).length > 0
        spacing: Theme.space.sm

        Repeater {
            model: sandboxes.status?.actions ?? []

            ShellButton {
                required property var modelData

                objectName: "sandboxAction:" + modelData.operation
                text: modelData.label
                primary: modelData.operation === "install"
                enabled: sandboxes.canRun
                onClicked: Shell.dispatch("sandboxSettings.run", { operation: modelData.operation })
            }
        }
    }

    Label {
        objectName: "sandboxManageReason"
        Layout.fillWidth: true
        visible: text.length > 0
        text: sandboxes.status?.manageReason ?? ""
        color: sandboxes.muted
        font.pixelSize: Theme.type.meta.size
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
    }
}
