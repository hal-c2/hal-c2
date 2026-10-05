import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The git pill: quick action + menu, with the commit, default-branch and
// publish dialogs rendered here from Shell.state.git (GitController).
// Progress and results are toasts, shown by Notifications.
RowLayout {
    id: git

    readonly property var model: Shell.state.git ?? null
    readonly property bool ready: model !== null && model.available
    // The running action's stage, elapsed time and last hook line, or null.
    readonly property var progress: ready ? model.progress ?? null : null
    // Why a checkout the MC cannot reach (its machine is offline) has no git actions.
    readonly property string unavailableReason: model !== null && !model.available ? (model.unavailableReason ?? "") : ""
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")

    // Icon-only pill, for narrow header strips.
    property bool compact: false

    spacing: 0
    visible: ready || unavailableReason !== ""

    readonly property string quickIcon: {
        if (!ready) {
            return "git-commit-horizontal";
        }
        switch (model.quickAction.kind) {
        case "open_pr":
            return "git-pull-request";
        case "open_publish":
            return "cloud-upload";
        case "run_pull":
            return "git-merge";
        default:
            return model.quickAction.label.toLowerCase().indexOf("push") >= 0 ? "cloud-upload" : "git-commit-horizontal";
        }
    }

    Text {
        objectName: "gitUnavailable"
        visible: git.unavailableReason !== ""
        text: git.compact ? qsTr("No git") : qsTr("Git unavailable")
        color: git.muted
        font.pixelSize: Math.round(12 * Theme.fontScale)

        HoverHandler {
            id: unavailableHover
        }

        ToolTip.visible: unavailableHover.hovered
        ToolTip.text: git.unavailableReason
    }

    ShellButton {
        implicitHeight: 24
        font.pixelSize: Math.round(12 * Theme.fontScale)
        iconName: "git-branch"
        visible: git.ready && !git.model.isRepo
        enabled: git.ready && !git.model.initPending
        text: git.ready && git.model.initPending ? qsTr("Initializing…") : qsTr("Initialize Git")
        onClicked: Shell.dispatch("git.init")
    }

    ShellSplitButton {
        visible: git.ready && git.model.isRepo
        enabled: git.ready && !git.model.busy
        actionEnabled: git.ready && git.model.quickAction.disabledReason === null
        compact: git.compact
        iconName: git.quickIcon
        // A running action says its stage and how long it has run.
        text: !git.ready ? "" : git.progress ? qsTr("%1 %2").arg(git.progress.stage).arg(git.progress.elapsed) : git.model.quickAction.label
        toolTip: !git.ready ? "" : git.progress ? (git.progress.hookLine ?? "") : (git.model.quickAction.disabledReason ?? "")
        onClicked: Shell.dispatch("git.quick")
        onMenuRequested: {
            Shell.dispatch("git.refresh");
            menu.open();
        }

        ShellMenu {
            id: menu

            y: parent.height + 4
            x: parent.width - width

            Instantiator {
                model: git.ready ? git.model.menu : []

                delegate: ShellMenuItem {
                    required property var modelData
                    required property int index

                    text: modelData.disabledReason ? modelData.label + "  · " + modelData.disabledReason : modelData.label
                    enabled: modelData.disabledReason === null
                    onTriggered: {
                        if (modelData.id === "commit") {
                            commitDialog.reset();
                            commitDialog.open();
                        } else {
                            Shell.dispatch("git.menu", {
                                id: modelData.id
                            });
                        }
                    }
                }

                onObjectAdded: (index, object) => menu.insertItem(index, object)
                onObjectRemoved: (index, object) => menu.removeItem(object)
            }

            ShellMenuItem {
                visible: git.ready && git.model.canPublish
                height: visible ? implicitHeight : 0
                text: qsTr("Publish repository…")
                iconName: "cloud-upload"
                onTriggered: Shell.dispatch("git.publish")
            }

            Instantiator {
                model: git.ready ? git.model.hints : []

                delegate: ShellMenuItem {
                    required property var modelData

                    text: modelData
                    enabled: false
                }

                onObjectAdded: (index, object) => menu.addItem(object)
                onObjectRemoved: (index, object) => menu.removeItem(object)
            }
        }
    }

    // ---- Commit dialog -------------------------------------------------
    Popup {
        id: commitDialog
        objectName: "commitDialog"

        property var excluded: ({})
        readonly property bool hasSelectedFiles: git.ready && git.model.files.some(file => !excluded[file.path])

        function reset() {
            message.text = "";
            excluded = {};
        }
        function selectedPaths() {
            const all = git.model.files.map(file => file.path);
            const chosen = all.filter(path => !commitDialog.excluded[path]);
            return chosen.length === all.length ? null : chosen;
        }
        function submit(featureBranch) {
            const paths = selectedPaths();
            if (paths !== null && paths.length === 0) {
                return;
            }
            Shell.dispatch("git.commit", {
                message: message.text,
                filePaths: paths,
                featureBranch: featureBranch
            });
            close();
        }

        parent: Overlay.overlay
        scale: Shell.state.layout?.zoom ?? 1
        transformOrigin: Item.TopLeft
        x: Math.round((parent.width - width * scale) / 2)
        y: Math.round((parent.height - height * scale) / 2)
        width: 520
        modal: true
        padding: 16

        background: Rectangle {
            radius: Theme.radius
            color: Theme.palette.color("surfaceOverlay", "#18181b")
            border.color: Theme.palette.color("border", "#27272a")
            border.width: 1
        }

        contentItem: ColumnLayout {
            spacing: 10

            Text {
                text: qsTr("Commit changes")
                color: git.foreground
                font.pixelSize: Math.round(15 * Theme.fontScale)
                font.bold: true
            }

            Text {
                Layout.fillWidth: true
                text: qsTr("Review and confirm your commit. Leave the message blank to auto-generate one.")
                color: git.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            Text {
                visible: git.ready && git.model.isDefaultRef
                text: qsTr("Warning: committing on the default branch %1").arg(git.ready ? (git.model.branch ?? "") : "")
                color: Theme.palette.color("warning", "#e0af68")
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }

            ListView {
                id: fileList

                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(Math.max(count, 1) * 30, 220)
                clip: true
                model: git.ready ? git.model.files : []
                boundsBehavior: Flickable.StopAtBounds

                delegate: RowLayout {
                    required property var modelData

                    width: fileList.width
                    height: 30
                    spacing: 8

                    CheckBox {
                        objectName: "fileCheck-" + modelData.path
                        checked: !commitDialog.excluded[modelData.path]
                        onToggled: {
                            const next = Object.assign({}, commitDialog.excluded);
                            if (checked) {
                                delete next[modelData.path];
                            } else {
                                next[modelData.path] = true;
                            }
                            commitDialog.excluded = next;
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: modelData.path
                        color: git.foreground
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        elide: Text.ElideMiddle
                    }

                    ShellButton {
                        objectName: "fileOpen-" + modelData.path
                        subtle: true
                        iconName: "square-arrow-out-up-right"
                        iconSize: 12
                        iconTint: git.muted
                        implicitWidth: 22
                        implicitHeight: 22
                        Accessible.name: qsTr("Open %1 in the editor").arg(modelData.path)
                        ToolTip.visible: hovered
                        ToolTip.text: qsTr("Open in editor")
                        onClicked: Shell.dispatch("workspace.openFile", {
                            path: modelData.path
                        })
                    }

                    Text {
                        text: "+" + modelData.insertions
                        color: Theme.palette.color("update", "#22c55e")
                        font.pixelSize: Math.round(11 * Theme.fontScale)
                    }

                    Text {
                        text: "−" + modelData.deletions
                        color: Theme.palette.color("error", "#ef4444")
                        font.pixelSize: Math.round(11 * Theme.fontScale)
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 84
                radius: Theme.radius
                color: Theme.palette.color("input", "#141416")
                border.color: message.activeFocus ? Theme.palette.color("focus", "#3b82f6") : Theme.palette.color("border", "#27272a")

                ScrollView {
                    anchors.fill: parent
                    anchors.margins: 8

                    TextArea {
                        id: message

                        placeholderText: qsTr("Commit message (optional)")
                        placeholderTextColor: git.muted
                        color: git.foreground
                        wrapMode: TextEdit.Wrap
                        background: null
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Item {
                    Layout.fillWidth: true
                }

                ShellButton {
                    objectName: "commitCancel"
                    text: qsTr("Cancel")
                    onClicked: commitDialog.close()
                }

                ShellButton {
                    objectName: "commitNewBranch"
                    text: qsTr("Commit on new branch")
                    enabled: commitDialog.hasSelectedFiles
                    onClicked: commitDialog.submit(true)
                }

                ShellButton {
                    objectName: "commitSelected"
                    primary: true
                    text: qsTr("Commit")
                    enabled: commitDialog.hasSelectedFiles
                    onClicked: commitDialog.submit(false)
                }
            }
        }
    }

    // ---- Default-branch confirmation ---------------------------------
    Popup {
        id: confirmDialog

        readonly property var pending: git.ready ? git.model.pendingDefaultBranch : null

        parent: Overlay.overlay
        scale: Shell.state.layout?.zoom ?? 1
        transformOrigin: Item.TopLeft
        x: Math.round((parent.width - width * scale) / 2)
        y: Math.round((parent.height - height * scale) / 2)
        width: 460
        modal: true
        padding: 16
        visible: pending !== null
        closePolicy: Popup.NoAutoClose

        background: Rectangle {
            radius: Theme.radius
            color: Theme.palette.color("surfaceOverlay", "#18181b")
            border.color: Theme.palette.color("border", "#27272a")
            border.width: 1
        }

        contentItem: ColumnLayout {
            spacing: 10

            Text {
                Layout.fillWidth: true
                text: confirmDialog.pending ? confirmDialog.pending.title : ""
                color: git.foreground
                font.pixelSize: Math.round(15 * Theme.fontScale)
                font.bold: true
                wrapMode: Text.Wrap
            }

            Text {
                Layout.fillWidth: true
                text: confirmDialog.pending ? confirmDialog.pending.description : ""
                color: git.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Item {
                    Layout.fillWidth: true
                }

                ShellButton {
                    text: qsTr("Abort")
                    onClicked: Shell.dispatch("git.defaultBranch", {
                        choice: "abort"
                    })
                }

                ShellButton {
                    text: confirmDialog.pending ? confirmDialog.pending.featureBranchLabel : ""
                    onClicked: Shell.dispatch("git.defaultBranch", {
                        choice: "featureBranch"
                    })
                }

                ShellButton {
                    primary: true
                    text: confirmDialog.pending ? confirmDialog.pending.continueLabel : ""
                    onClicked: Shell.dispatch("git.defaultBranch", {
                        choice: "continue"
                    })
                }
            }
        }
    }
    // ---- Publish repository ------------------------------------------
    // Three steps: the host (and whether it is ready), the repository and
    // its visibility, then a summary to confirm.
    Popup {
        id: publishDialog
        objectName: "publishDialog"

        // Open while GitController has the dialog open; Escape and Cancel tell it.
        readonly property var form: git.ready ? (git.model.publishing ?? null) : null
        readonly property bool busy: form?.busy ?? false
        readonly property var hosts: form?.hosts ?? []
        readonly property var host: hosts.length > 0 ? hosts[Math.max(0, provider.currentIndex)] : null
        // 0: host, 1: repository, 2: summary.
        property int step: 0

        onFormChanged: {
            if (form !== null && !opened) {
                open();
            } else if (form === null && opened) {
                close();
            }
        }

        parent: Overlay.overlay
        scale: Shell.state.layout?.zoom ?? 1
        transformOrigin: Item.TopLeft
        x: Math.round((parent.width - width * scale) / 2)
        y: Math.round((parent.height - height * scale) / 2)
        width: 460
        modal: true
        padding: 16
        closePolicy: Popup.CloseOnEscape
        onClosed: {
            if (form !== null) {
                Shell.dispatch("git.publish.cancel");
            }
        }
        onOpened: {
            repository.text = "";
            step = 0;
        }

        background: Rectangle {
            radius: Theme.radius
            color: Theme.palette.color("surfaceOverlay", "#18181b")
            border.color: Theme.palette.color("border", "#27272a")
            border.width: 1
        }

        contentItem: ColumnLayout {
            spacing: 10

            Text {
                text: qsTr("Publish repository")
                color: git.foreground
                font.pixelSize: Math.round(15 * Theme.fontScale)
                font.bold: true
            }

            Text {
                objectName: "publishStep"
                Layout.fillWidth: true
                text: [qsTr("Step 1 of 3 · Host"), qsTr("Step 2 of 3 · Repository"), qsTr("Step 3 of 3 · Summary")][publishDialog.step]
                color: git.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }

            // The host.
            ComboBox {
                id: provider

                objectName: "publishHost"
                Layout.fillWidth: true
                visible: publishDialog.step === 0
                popup.scale: publishDialog.scale
                popup.transformOrigin: Item.TopLeft
                textRole: "label"
                valueRole: "value"
                model: publishDialog.hosts
            }
            Text {
                objectName: "publishHostHint"
                Layout.fillWidth: true
                visible: publishDialog.step === 0 && text.length > 0
                text: publishDialog.host?.hint ?? ""
                color: Theme.palette.color("warning", "#e0af68")
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            // The repository and who sees it.
            TextField {
                id: repository

                objectName: "publishRepository"
                Layout.fillWidth: true
                visible: publishDialog.step === 1
                placeholderText: qsTr("owner/repository")
                placeholderTextColor: git.muted
                color: git.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
                onAccepted: nextButton.clicked()
            }
            ComboBox {
                id: visibility

                objectName: "publishVisibility"
                visible: publishDialog.step === 1
                popup.scale: publishDialog.scale
                popup.transformOrigin: Item.TopLeft
                textRole: "label"
                valueRole: "value"
                model: [
                    {
                        value: "private",
                        label: qsTr("Private")
                    },
                    {
                        value: "public",
                        label: qsTr("Public")
                    }
                ]
            }

            // What publishing will do.
            Text {
                objectName: "publishSummary"
                Layout.fillWidth: true
                visible: publishDialog.step === 2
                text: qsTr("Create the %1 repository %2 on %3, add it as the remote origin and push %4.").arg(visibility.currentValue === "public" ? qsTr("public") : qsTr("private")).arg(repository.text.trim()).arg(publishDialog.host?.label ?? "").arg(git.ready && git.model.branch ? git.model.branch : qsTr("this branch"))
                color: git.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            Text {
                objectName: "publishError"
                Layout.fillWidth: true
                visible: text !== ""
                text: publishDialog.form?.error ?? ""
                color: Theme.palette.color("error", "#ef4444")
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Item {
                    Layout.fillWidth: true
                }

                ShellButton {
                    objectName: "publishBack"
                    text: publishDialog.step === 0 ? qsTr("Cancel") : qsTr("Back")
                    enabled: !publishDialog.busy
                    onClicked: {
                        if (publishDialog.step === 0) {
                            publishDialog.close();
                        } else {
                            publishDialog.step -= 1;
                        }
                    }
                }

                ShellButton {
                    id: nextButton

                    objectName: "publishNext"
                    primary: true
                    visible: publishDialog.step < 2
                    text: qsTr("Next")
                    // A host that is not ready goes no further.
                    enabled: publishDialog.step === 0 ? (publishDialog.host?.ready ?? false) : repository.text.trim() !== ""
                    onClicked: {
                        if (enabled) {
                            publishDialog.step += 1;
                        }
                    }
                }

                ShellButton {
                    objectName: "publishConfirm"
                    primary: true
                    visible: publishDialog.step === 2
                    text: publishDialog.busy ? qsTr("Publishing…") : qsTr("Publish")
                    enabled: !publishDialog.busy
                    onClicked: Shell.dispatch("git.publish.submit", {
                        provider: provider.currentValue,
                        visibility: visibility.currentValue,
                        repository: repository.text.trim()
                    })
                }
            }
        }
    }
}
