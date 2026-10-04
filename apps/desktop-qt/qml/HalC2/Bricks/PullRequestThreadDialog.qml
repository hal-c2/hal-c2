import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Starting a thread on a pull request (Shell.state.pullRequestThread,
// PullRequestThreadController): the user pastes a link or a number, sees the
// pull request's title and branches, then chooses the local checkout or a
// worktree of its own.
Dialog {
    id: dialog

    readonly property var flow: Shell.state.pullRequestThread ?? null
    readonly property var pullRequest: flow?.pullRequest ?? null
    readonly property bool busy: flow !== null && (flow.step === "resolving" || flow.step === "starting")
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")

    objectName: "pullRequestThreadDialog"
    parent: Overlay.overlay
    modal: true
    anchors.centerIn: parent
    scale: Shell.state.layout?.zoom ?? 1
    transformOrigin: Item.TopLeft
    width: Math.min(460, (parent?.width ?? 492) / scale - 32)
    padding: 20
    closePolicy: Popup.CloseOnEscape
    onFlowChanged: flow !== null ? open() : close()
    onOpened: {
        reference.text = "";
        reference.forceActiveFocus();
    }
    onRejected: Shell.dispatch("pullRequestThread.cancel", {})

    background: Rectangle {
        color: Theme.palette.color("surfaceOverlay", "#18181b")
        border.color: Theme.palette.color("border", "#27272a")
        radius: Math.min(Theme.radius, 16)
    }
    contentItem: ColumnLayout {
        spacing: 10

        Label {
            Layout.fillWidth: true
            text: qsTr("Start a thread on a pull request")
            color: dialog.foreground
            font.pixelSize: Math.round(17 * Theme.fontScale)
            font.weight: Font.DemiBold
            wrapMode: Text.Wrap
        }
        ShellTextField {
            id: reference

            objectName: "pullRequestThreadReference"
            Layout.fillWidth: true
            placeholderText: qsTr("A pull request link, 42 or #42")
            enabled: !dialog.busy
            Accessible.name: qsTr("Pull request")
            onAccepted: Shell.dispatch("pullRequestThread.resolve", {
                reference: text
            })
        }
        Label {
            objectName: "pullRequestThreadError"
            Layout.fillWidth: true
            visible: text.length > 0
            text: dialog.flow?.error ?? ""
            color: Theme.palette.color("error", "#ef4444")
            font.pixelSize: Math.round(12 * Theme.fontScale)
            wrapMode: Text.Wrap
        }
        // What is about to be checked out, before choosing where.
        ColumnLayout {
            Layout.fillWidth: true
            visible: dialog.pullRequest !== null
            spacing: 2

            Label {
                objectName: "pullRequestThreadTitle"
                Layout.fillWidth: true
                text: dialog.pullRequest ? qsTr("#%1 %2").arg(dialog.pullRequest.number).arg(dialog.pullRequest.title) : ""
                color: dialog.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.Medium
                wrapMode: Text.Wrap
            }
            Label {
                objectName: "pullRequestThreadBranches"
                Layout.fillWidth: true
                text: dialog.pullRequest?.branches ?? ""
                color: dialog.muted
                font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
                font.pixelSize: Math.round(12 * Theme.fontScale)
                elide: Text.ElideMiddle
            }
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 6
            spacing: 8

            ShellButton {
                objectName: "pullRequestThreadCancel"
                text: qsTr("Cancel")
                enabled: dialog.flow?.step !== "starting"
                onClicked: dialog.reject()
            }
            Item {
                Layout.fillWidth: true
            }
            ShellButton {
                objectName: "pullRequestThreadFind"
                visible: dialog.pullRequest === null
                primary: true
                text: dialog.flow?.step === "resolving" ? qsTr("Looking…") : qsTr("Find")
                enabled: !dialog.busy && reference.text.trim().length > 0
                onClicked: Shell.dispatch("pullRequestThread.resolve", {
                    reference: reference.text
                })
            }
            ShellButton {
                objectName: "pullRequestThreadLocal"
                visible: dialog.pullRequest !== null
                text: qsTr("Local checkout")
                enabled: !dialog.busy
                onClicked: Shell.dispatch("pullRequestThread.start", {
                    mode: "local"
                })
            }
            ShellButton {
                objectName: "pullRequestThreadWorktree"
                visible: dialog.pullRequest !== null
                primary: true
                text: dialog.flow?.step === "starting" ? qsTr("Starting…") : qsTr("New worktree")
                enabled: !dialog.busy
                onClicked: Shell.dispatch("pullRequestThread.start", {
                    mode: "worktree"
                })
            }
        }
    }
}
