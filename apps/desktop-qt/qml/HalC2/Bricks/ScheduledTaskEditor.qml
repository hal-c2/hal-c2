pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import "js/scheduledTasks.js" as Tasks

// Creates or edits a scheduled task (`scheduledTasks.editor`). The draft is
// the dialog's own until saved; the controller checks it and says what is
// missing.
Dialog {
    id: dialog

    readonly property var editor: Shell.state.scheduledTasks?.editor ?? null
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property var weekdayNames: [qsTr("Sun"), qsTr("Mon"), qsTr("Tue"), qsTr("Wed"), qsTr("Thu"), qsTr("Fri"), qsTr("Sat")]
    readonly property var workspaceModes: ["worktree", "root", "existing_worktree"]
    property var draft: ({})
    property int seq: -1

    function set(key, value) {
        const next = Object.assign({}, draft);
        next[key] = value;
        draft = next;
    }

    function toggleDay(day) {
        set("weekdays", Tasks.toggleDay(draft.weekdays, day));
    }

    // The project's branches matching what is typed as the base branch.
    function listBranches() {
        Shell.dispatch("scheduledTasks.branches", { projectId: draft.projectId ?? "", query: draft.baseRef ?? "" });
    }

    objectName: "scheduledTaskEditor"
    parent: Overlay.overlay
    modal: true
    anchors.centerIn: parent
    scale: Shell.state.layout?.zoom ?? 1
    transformOrigin: Item.TopLeft
    width: Math.min(560, (parent?.width ?? 592) / scale - 32)
    height: Math.min(implicitHeight, (parent?.height ?? 700) / scale - 32)
    padding: 20
    closePolicy: Popup.CloseOnEscape
    title: editor?.editing ? qsTr("Edit scheduled task") : qsTr("New scheduled task")
    // Each editor opened (another task, or another environment) starts from its draft.
    onEditorChanged: {
        if (editor === null) {
            close();
            return;
        }
        if (editor.seq !== seq) {
            seq = editor.seq;
            draft = Object.assign({}, editor.draft);
        }
        open();
    }
    onRejected: Shell.dispatch("scheduledTasks.close")

    background: Rectangle {
        color: Theme.palette.color("surfaceOverlay", "#18181b")
        border.color: Theme.palette.color("border", "#27272a")
        radius: Math.min(Theme.radius, 16)
    }
    header: Label {
        text: dialog.title
        padding: 20
        bottomPadding: 4
        font.pixelSize: Math.round(17 * Theme.fontScale)
        font.weight: Font.DemiBold
        color: dialog.foreground
    }

    component Caption: Label {
        color: Theme.palette.color("textMuted", "#a1a1aa")
        font.pixelSize: Math.round(12 * Theme.fontScale)
    }

    contentItem: Flickable {
        implicitHeight: form.implicitHeight
        contentHeight: form.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar {}

        ColumnLayout {
            id: form

            width: parent.width
            spacing: 8

            Label {
                objectName: "disconnected"
                Layout.fillWidth: true
                visible: dialog.editor !== null && !dialog.editor.connected
                text: qsTr("Reconnect this environment before saving.")
                color: Theme.palette.color("warning", "#fbbf24")
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            Label {
                objectName: "missing"
                Layout.fillWidth: true
                visible: text.length > 0
                text: dialog.editor?.error ? dialog.editor.error
                    : dialog.editor?.missing ? qsTr("This scheduled task no longer exists.") : ""
                color: Theme.palette.color("error", "#ef4444")
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            Caption {
                visible: !(dialog.editor?.editing ?? true) && (dialog.editor?.environments ?? []).length > 1
                text: qsTr("Environment")
            }
            ShellComboBox {
                objectName: "environment"
                Layout.fillWidth: true
                outline: true
                visible: !(dialog.editor?.editing ?? true) && (dialog.editor?.environments ?? []).length > 1
                model: (dialog.editor?.environments ?? []).map(environment => environment.label)
                currentIndex: (dialog.editor?.environments ?? []).findIndex(environment => environment.id === dialog.editor.environmentId)
                onActivated: index => Shell.dispatch("scheduledTasks.editorEnvironment", { id: dialog.editor.environments[index].id })
            }

            Caption { text: qsTr("Title") }
            ShellTextField {
                objectName: "title"
                Layout.fillWidth: true
                text: dialog.draft.title ?? ""
                placeholderText: qsTr("Check Sentry")
                onTextEdited: dialog.set("title", text)
            }

            Caption { text: qsTr("Prompt") }
            TextArea {
                objectName: "prompt"
                Layout.fillWidth: true
                Layout.preferredHeight: 96
                text: dialog.draft.prompt ?? ""
                wrapMode: TextEdit.Wrap
                color: dialog.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
                placeholderText: qsTr("What should the agent do each run?")
                placeholderTextColor: Theme.palette.color("placeholder", "#71717a")
                background: Rectangle {
                    radius: Math.min(Theme.radius, 8)
                    color: Theme.palette.color("input", "#18181b")
                    border.color: Theme.palette.color("border", "#27272a")
                }
                onTextChanged: if (text !== (dialog.draft.prompt ?? "")) dialog.set("prompt", text)
            }

            Caption { text: qsTr("Project") }
            ShellComboBox {
                objectName: "project"
                Layout.fillWidth: true
                outline: true
                model: (dialog.editor?.projects ?? []).map(project => project.title)
                currentIndex: (dialog.editor?.projects ?? []).findIndex(project => project.id === dialog.draft.projectId)
                onActivated: index => dialog.set("projectId", dialog.editor.projects[index].id)
            }

            Caption { text: qsTr("Model") }
            ShellComboBox {
                objectName: "model"
                Layout.fillWidth: true
                outline: true
                model: (dialog.editor?.models ?? []).map(model => model.label)
                currentIndex: (dialog.editor?.models ?? []).findIndex(model => model.key === dialog.draft.modelKey)
                onActivated: index => dialog.set("modelKey", dialog.editor.models[index].key)
            }

            Caption { text: qsTr("Schedule") }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                ShellComboBox {
                    objectName: "scheduleMode"
                    outline: true
                    implicitWidth: 150
                    model: [qsTr("At a time of day"), qsTr("Every few minutes")]
                    currentIndex: dialog.draft.scheduleMode === "interval" ? 1 : 0
                    onActivated: index => dialog.set("scheduleMode", index === 1 ? "interval" : "fixed")
                }

                ShellTextField {
                    objectName: "timeOfDay"
                    visible: dialog.draft.scheduleMode !== "interval"
                    implicitWidth: 80
                    text: dialog.draft.timeOfDay ?? "09:00"
                    inputMask: "99:99"
                    onTextEdited: dialog.set("timeOfDay", text)
                }

                ShellTextField {
                    objectName: "intervalMinutes"
                    visible: dialog.draft.scheduleMode === "interval"
                    implicitWidth: 80
                    text: dialog.draft.intervalMinutes ?? "15"
                    onTextEdited: dialog.set("intervalMinutes", text)
                }

                Caption {
                    visible: dialog.draft.scheduleMode === "interval"
                    text: qsTr("minutes")
                }
            }

            Caption {
                objectName: "legacyInterval"
                Layout.fillWidth: true
                visible: (dialog.editor?.legacyInterval ?? false) && dialog.draft.scheduleMode === "interval"
                text: qsTr("This task uses a legacy interval below one minute. Saving updates it to at least one minute.")
                wrapMode: Text.Wrap
            }

            Flow {
                Layout.fillWidth: true
                visible: dialog.draft.scheduleMode !== "interval"
                spacing: 4

                Repeater {
                    model: 7

                    delegate: ShellButton {
                        required property int index
                        objectName: "weekday" + index
                        subtle: !(dialog.draft.weekdays ?? []).includes(index)
                        primary: (dialog.draft.weekdays ?? []).includes(index)
                        text: dialog.weekdayNames[index]
                        onClicked: dialog.toggleDay(index)
                    }
                }
            }

            Caption { text: qsTr("Workspace") }
            ShellComboBox {
                objectName: "workspace"
                Layout.fillWidth: true
                outline: true
                model: [qsTr("Create a new worktree"), qsTr("Use the project checkout"), qsTr("Use a specific checkout")]
                currentIndex: Math.max(0, dialog.workspaceModes.indexOf(dialog.draft.workspaceMode))
                onActivated: index => dialog.set("workspaceMode", dialog.workspaceModes[index])
            }

            RowLayout {
                Layout.fillWidth: true
                visible: dialog.draft.workspaceMode === "worktree"
                spacing: 8

                ShellTextField {
                    id: baseRef

                    objectName: "baseRef"
                    Layout.fillWidth: true
                    text: dialog.draft.baseRef ?? "main"
                    placeholderText: qsTr("Base branch")
                    onTextEdited: {
                        dialog.set("baseRef", text);
                        branchQuery.restart();
                        branches.open();
                    }
                    onActiveFocusChanged: if (activeFocus) {
                        dialog.listBranches();
                        branches.open();
                    }

                    // Typing asks once it pauses, not per keystroke.
                    Timer {
                        id: branchQuery
                        interval: 150
                        onTriggered: dialog.listBranches()
                    }

                    Popup {
                        id: branches

                        objectName: "branches"
                        scale: dialog.scale
                        transformOrigin: Item.TopLeft
                        y: baseRef.height + 4
                        width: baseRef.width
                        height: Math.min(implicitHeight, 240)
                        padding: 4
                        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
                        background: Rectangle {
                            radius: Math.min(Theme.radius, 8)
                            color: Theme.palette.color("surfaceOverlay", "#18181b")
                            border.color: Theme.palette.color("border", "#27272a")
                        }
                        contentItem: ListView {
                            implicitHeight: Math.max(contentHeight, 28)
                            clip: true
                            model: dialog.editor?.branches ?? []
                            boundsBehavior: Flickable.StopAtBounds
                            delegate: ShellButton {
                                required property var modelData
                                width: ListView.view.width
                                subtle: true
                                text: modelData.name + (modelData.isDefault ? qsTr("  default") : modelData.current ? qsTr("  current") : "")
                                onClicked: {
                                    dialog.set("baseRef", modelData.name);
                                    branches.close();
                                }
                            }
                            footer: Caption {
                                visible: (dialog.editor?.branches ?? []).length === 0
                                height: visible ? implicitHeight + 8 : 0
                                leftPadding: 8
                                topPadding: 4
                                text: dialog.editor?.branchesLoading ? qsTr("Loading branches…") : qsTr("No matching branches")
                            }
                        }
                    }
                }

                CheckBox {
                    objectName: "startFromOrigin"
                    text: qsTr("Fetch from origin first")
                    checked: dialog.draft.startFromOrigin ?? true
                    onToggled: dialog.set("startFromOrigin", checked)
                }
            }

            ShellTextField {
                objectName: "checkoutPath"
                Layout.fillWidth: true
                visible: dialog.draft.workspaceMode === "existing_worktree"
                text: dialog.draft.checkoutPath ?? ""
                placeholderText: qsTr("Path of the checkout to run in")
                onTextEdited: dialog.set("checkoutPath", text)
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 8
                spacing: 8

                Switch {
                    objectName: "enabled"
                    checked: dialog.draft.enabled ?? true
                    onToggled: dialog.set("enabled", checked)
                }
                Caption {
                    Layout.fillWidth: true
                    text: qsTr("Run on this schedule")
                }
                ShellButton {
                    objectName: "cancel"
                    text: qsTr("Cancel")
                    onClicked: dialog.reject()
                }
                ShellButton {
                    objectName: "save"
                    primary: true
                    enabled: !(dialog.editor?.saving ?? false)
                    text: dialog.editor?.editing ? qsTr("Save") : qsTr("Create task")
                    onClicked: Shell.dispatch("scheduledTasks.save", { draft: dialog.draft })
                }
            }
        }
    }
}
