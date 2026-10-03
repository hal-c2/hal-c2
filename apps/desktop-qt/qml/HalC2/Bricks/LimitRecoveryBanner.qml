import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The open thread stopped on a usage limit (Shell.state.limitRecovery,
// LimitRecoveryController): when the limit resets, and what to do until then.
Rectangle {
    id: banner

    readonly property var recovery: Shell.state.limitRecovery ?? null
    readonly property color warning: Theme.palette.color("warning", "#f59e0b")

    objectName: "limitRecovery"
    visible: recovery !== null
    implicitHeight: visible ? column.implicitHeight + 16 : 0
    color: Qt.alpha(warning, 0.1)

    ColumnLayout {
        id: column

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 8
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        spacing: 4

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            ShellIcon {
                name: "circle-alert"
                size: 14
                color: banner.warning
            }
            Label {
                text: banner.recovery?.title ?? ""
                color: banner.warning
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.Medium
            }
            Label {
                objectName: "limitRecoveryDescription"
                Layout.fillWidth: true
                text: banner.recovery?.description ?? ""
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Math.round(12 * Theme.fontScale)
                elide: Text.ElideRight
            }
            ShellButton {
                objectName: "limitRecoveryResume"
                visible: banner.recovery?.canSchedule === true
                subtle: true
                text: banner.recovery?.scheduled === true ? qsTr("Cancel auto-resume") : qsTr("Resume at reset")
                onClicked: Shell.dispatch("limitRecovery.resume", {})
            }
            ShellButton {
                objectName: "limitRecoverySnooze"
                visible: banner.recovery?.canSchedule === true && banner.recovery?.snoozed !== true
                enabled: banner.recovery?.canSnooze === true
                subtle: true
                text: qsTr("Snooze until reset")
                onClicked: Shell.dispatch("limitRecovery.snooze", {})
            }
        }

        Label {
            Layout.fillWidth: true
            visible: text.length > 0
            text: banner.recovery?.error ?? ""
            color: Theme.palette.color("error", "#ef4444")
            font.pixelSize: Math.round(12 * Theme.fontScale)
            wrapMode: Text.Wrap
        }
    }
}
