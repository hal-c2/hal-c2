import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Starting a thread on a pull request (Shell.state.pullRequestThread,
// PullRequestThreadController): the user pastes a link, a checkout command or
// a number, sees the pull request's title and branches once it resolves, then
// chooses the local checkout or a worktree of its own. While that is prepared
// the dialog cannot be left.
Dialog {
    id: dialog

    readonly property var flow: Shell.state.pullRequestThread ?? null
    readonly property var pullRequest: flow?.pullRequest ?? null
    readonly property bool starting: flow?.step === "starting"
    readonly property bool choosable: flow?.step === "choose"
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")

    objectName: "pullRequestThreadDialog"
    parent: Overlay.overlay
    modal: true
    anchors.centerIn: parent
    scale: Shell.state.layout?.zoom ?? 1
    transformOrigin: Item.TopLeft
    width: Math.min(560, (parent?.width ?? 592) / scale - 32)
    padding: 20
    closePolicy: dialog.starting ? Popup.NoAutoClose : Popup.CloseOnEscape
    onFlowChanged: flow !== null ? open() : close()
    onOpened: {
        reference.text = flow?.text ?? "";
        reference.forceActiveFocus();
        reference.selectAll();
    }
    onRejected: Shell.dispatch("pullRequestThread.cancel", {})

    Overlay.modal: ShellScrim {}
    background: ShellPopoverSurface {}
    contentItem: ColumnLayout {
        spacing: Theme.space.sm

        Label {
            Layout.fillWidth: true
            text: qsTr("Checkout pull request")
            color: dialog.foreground
            font.pixelSize: Theme.type.title.size
            font.weight: Font.DemiBold
            wrapMode: Text.Wrap
        }
        Label {
            Layout.fillWidth: true
            text: qsTr("Resolve a pull request, then create the draft thread in the main repo or in a dedicated worktree.")
            color: dialog.muted
            font.pixelSize: Theme.type.body.size
            wrapMode: Text.Wrap
        }
        Label {
            Layout.topMargin: 4
            text: qsTr("Pull request")
            color: dialog.foreground
            font.pixelSize: Theme.type.meta.size
            font.weight: Font.Medium
        }
        ShellTextField {
            id: reference

            objectName: "pullRequestThreadReference"
            Layout.fillWidth: true
            placeholderText: qsTr("PR URL, checkout command, or #42")
            enabled: !dialog.starting
            Accessible.name: qsTr("Pull request")
            onTextChanged: if (dialog.flow !== null)
                Shell.dispatch("pullRequestThread.edit", {
                    reference: text
                })
            onAccepted: if (dialog.choosable)
                Shell.dispatch("pullRequestThread.start", {
                    mode: "worktree"
                })
        }
        // What is about to be checked out, before choosing where.
        Rectangle {
            Layout.fillWidth: true
            visible: dialog.pullRequest !== null
            implicitHeight: resolved.implicitHeight + 24
            radius: Theme.radiusLg
            color: Theme.palette.color("surfaceRaised", "#27272a")
            border.color: Theme.palette.color("border", "#3f3f46")

            RowLayout {
                id: resolved

                anchors.fill: parent
                anchors.margins: 12
                spacing: 12

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    Label {
                        objectName: "pullRequestThreadTitle"
                        Layout.fillWidth: true
                        text: dialog.pullRequest?.title ?? ""
                        color: dialog.foreground
                        font.pixelSize: Theme.type.body.size
                        font.weight: Font.Medium
                        elide: Text.ElideRight
                    }
                    Label {
                        objectName: "pullRequestThreadBranches"
                        Layout.fillWidth: true
                        text: dialog.pullRequest ? qsTr("#%1 · %2 to %3").arg(dialog.pullRequest.number).arg(dialog.pullRequest.headBranch).arg(dialog.pullRequest.baseBranch) : ""
                        color: dialog.muted
                        font.pixelSize: Theme.type.meta.size
                        elide: Text.ElideRight
                    }
                }
                Label {
                    Layout.alignment: Qt.AlignTop
                    readonly property string state: dialog.pullRequest?.state ?? ""
                    text: state.length > 0 ? state.charAt(0).toUpperCase() + state.slice(1) : ""
                    color: state === "merged" ? Theme.palette.color("merged", "#c4b5fd") : state === "open" ? Theme.palette.color("success", "#6ee7b7") : dialog.muted
                    font.pixelSize: Theme.type.meta.size
                }
            }
        }
        Label {
            objectName: "pullRequestThreadResolving"
            Layout.fillWidth: true
            visible: dialog.flow?.step === "resolving"
            text: qsTr("Resolving pull request...")
            color: dialog.muted
            font.pixelSize: Theme.type.meta.size
        }
        Label {
            objectName: "pullRequestThreadError"
            Layout.fillWidth: true
            visible: text.length > 0
            text: dialog.flow?.error ?? ""
            color: Theme.palette.color("errorForeground", "#ef4444")
            font.pixelSize: Theme.type.meta.size
            wrapMode: Text.Wrap
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.space.sm
            spacing: 8

            Item {
                Layout.fillWidth: true
            }
            ShellButton {
                objectName: "pullRequestThreadCancel"
                text: qsTr("Cancel")
                enabled: !dialog.starting
                onClicked: dialog.reject()
            }
            ShellButton {
                objectName: "pullRequestThreadLocal"
                text: dialog.starting && dialog.flow.mode === "local" ? qsTr("Preparing local...") : qsTr("Local")
                enabled: dialog.choosable
                onClicked: Shell.dispatch("pullRequestThread.start", {
                    mode: "local"
                })
            }
            ShellButton {
                objectName: "pullRequestThreadWorktree"
                primary: true
                text: dialog.starting && dialog.flow.mode === "worktree" ? qsTr("Preparing worktree...") : qsTr("Worktree")
                enabled: dialog.choosable
                onClicked: Shell.dispatch("pullRequestThread.start", {
                    mode: "worktree"
                })
            }
        }
    }
}
