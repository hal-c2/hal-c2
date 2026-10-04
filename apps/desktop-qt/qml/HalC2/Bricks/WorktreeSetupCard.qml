import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// How the open thread's new worktree is being prepared
// (Shell.state.worktreeSetup, WorktreeSetupController): one line saying where
// it stands, with the steps and why it failed behind "Details".
Rectangle {
    id: card

    readonly property var setup: Shell.state.worktreeSetup ?? null
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color accent: {
        if (setup === null) {
            return muted;
        }
        if (setup.phase === "failed") {
            return Theme.palette.color("error", "#ef4444");
        }
        return setup.label.endsWith("failed") ? Theme.palette.color("warning", "#f59e0b") : muted;
    }

    objectName: "worktreeSetup"
    visible: setup !== null
    implicitHeight: visible ? column.implicitHeight + 16 : 0
    color: Qt.alpha(Theme.palette.color("surfaceOverlay", "#18181b"), 0.6)

    ColumnLayout {
        id: column

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 8
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        spacing: 6

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            ShellIcon {
                name: "git-branch"
                size: 14
                color: card.accent
            }
            Label {
                objectName: "worktreeSetupLabel"
                Layout.fillWidth: true
                text: card.setup?.label ?? ""
                color: card.accent
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.Medium
                elide: Text.ElideRight
            }
            ShellButton {
                objectName: "worktreeSetupCancel"
                visible: card.setup?.canCancel === true
                subtle: true
                text: qsTr("Cancel")
                onClicked: Shell.dispatch("worktreeSetup.cancel", {})
            }
            ShellButton {
                objectName: "worktreeSetupDetails"
                subtle: true
                text: card.setup?.detailsOpen === true ? qsTr("Hide details") : qsTr("Details")
                onClicked: Shell.dispatch("worktreeSetup.details", {
                    open: card.setup?.detailsOpen !== true
                })
            }
        }

        Label {
            objectName: "worktreeSetupError"
            Layout.fillWidth: true
            visible: card.setup?.detailsOpen === true && text.length > 0
            text: card.setup?.error ?? ""
            color: Theme.palette.color("error", "#ef4444")
            font.pixelSize: Math.round(12 * Theme.fontScale)
            wrapMode: Text.Wrap
        }

        Repeater {
            model: card.setup?.detailsOpen === true ? card.setup.stages : []

            delegate: ColumnLayout {
                id: stage

                required property var modelData

                Layout.fillWidth: true
                spacing: 2

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Label {
                        Layout.fillWidth: true
                        text: stage.modelData.label
                        color: stage.modelData.status === "pending" || stage.modelData.status === "skipped" ? card.muted : card.foreground
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }
                    Label {
                        text: stage.modelData.detail.length > 0 ? stage.modelData.detail : stage.modelData.status
                        color: stage.modelData.status === "failed" ? Theme.palette.color("error", "#ef4444") : card.muted
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }
                }
                Label {
                    Layout.fillWidth: true
                    visible: stage.modelData.tail.length > 0
                    text: stage.modelData.tail.join("\n")
                    color: card.muted
                    font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
                    font.pixelSize: Math.round(11 * Theme.fontScale)
                    wrapMode: Text.WrapAnywhere
                }
            }
        }
    }
}
