import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → Scheduled Tasks, natively: each environment's tasks in the
// settings scope, and the editor that creates and edits them
// (ScheduledTasksController's `scheduledTasks`).
SettingsPage {
    id: tasks

    readonly property var state: Shell.state.scheduledTasks ?? null
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color danger: Theme.palette.color("error", "#ef4444")

    objectName: "scheduledTasksSettings"
    title: qsTr("Scheduled Tasks")

    component Task: RowLayout {
        id: task

        required property var modelData
        property string environmentId: ""
        readonly property var ids: ({ environmentId: environmentId, id: modelData.id })

        objectName: "scheduledTask:" + modelData.id
        Layout.fillWidth: true
        spacing: 12

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Label {
                    Layout.fillWidth: true
                    text: task.modelData.title
                    color: tasks.foreground
                    font.pixelSize: 13
                    font.weight: Font.Medium
                    elide: Text.ElideRight
                }

                Label {
                    objectName: "lastRun"
                    visible: text.length > 0
                    text: task.modelData.lastRun ?? ""
                    color: task.modelData.lastRunStatus === "failed" ? tasks.danger : tasks.muted
                    font.pixelSize: 11
                    leftPadding: 6
                    rightPadding: 6
                    topPadding: 1
                    bottomPadding: 1
                    background: Rectangle {
                        radius: Math.min(Theme.radius, 6)
                        color: "transparent"
                        border.color: Theme.palette.color("border", "#27272a")
                    }
                }
            }

            Label {
                objectName: "promptPreview"
                Layout.fillWidth: true
                text: task.modelData.prompt
                color: tasks.muted
                font.pixelSize: 12
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }

            Label {
                objectName: "when"
                Layout.fillWidth: true
                text: task.modelData.schedule + " · " + task.modelData.when
                color: tasks.muted
                font.pixelSize: 12
            }

            Label {
                objectName: "lastError"
                Layout.fillWidth: true
                visible: task.modelData.lastRunStatus === "failed"
                text: qsTr("Last run failed: %1").arg(task.modelData.lastRunError || qsTr("unknown error"))
                color: tasks.danger
                font.pixelSize: 12
                wrapMode: Text.Wrap
            }
        }

        Switch {
            objectName: "enabled"
            enabled: !task.modelData.busy
            checked: task.modelData.enabled
            Accessible.name: qsTr("Run %1 on its schedule").arg(task.modelData.title)
            onToggled: Shell.dispatch("scheduledTasks.enable", Object.assign({ enabled: checked }, task.ids))
        }

        ShellButton {
            objectName: "run"
            subtle: true
            enabled: !task.modelData.busy && task.modelData.lastRunStatus !== "running"
            text: task.modelData.lastRunStatus === "running" ? qsTr("Running") : qsTr("Run now")
            onClicked: Shell.dispatch("scheduledTasks.run", task.ids)
        }

        ShellButton {
            objectName: "edit"
            subtle: true
            text: qsTr("Edit")
            onClicked: Shell.dispatch("scheduledTasks.edit", task.ids)
        }

        ShellButton {
            objectName: "delete"
            subtle: true
            enabled: !task.modelData.busy
            text: qsTr("Delete")
            tint: tasks.danger
            onClicked: Shell.dispatch("scheduledTasks.delete", task.ids)
        }
    }

    SettingsScopeSentence {}

    RowLayout {
        Layout.fillWidth: true

        Label {
            Layout.fillWidth: true
            text: qsTr("Prompts sent to a project on a timer. The environment runs them while no client is open.")
            color: tasks.muted
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }

        ShellButton {
            objectName: "newTask"
            primary: true
            enabled: tasks.state?.canCreate ?? false
            text: qsTr("New task")
            onClicked: Shell.dispatch("scheduledTasks.new")
        }
    }

    Repeater {
        model: tasks.state?.environments ?? []

        delegate: ColumnLayout {
            id: environment

            required property var modelData

            objectName: "scheduledTasksEnvironment:" + modelData.id
            Layout.fillWidth: true
            spacing: 10

            Label {
                visible: environment.modelData.heading
                text: environment.modelData.label
                color: tasks.muted
                font.pixelSize: 12
                font.weight: Font.DemiBold
            }

            RowLayout {
                objectName: "notice"
                Layout.fillWidth: true
                visible: environment.modelData.status !== "ready" || environment.modelData.linkMissing
                         || environment.modelData.tasks.length === 0
                spacing: 12

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    Label {
                        text: {
                            switch (environment.modelData.status) {
                            case "disconnected": return qsTr("Environment disconnected");
                            case "error": return qsTr("Could not load scheduled tasks");
                            case "loading": return qsTr("Loading scheduled tasks…");
                            }
                            return environment.modelData.linkMissing ? qsTr("Task unavailable") : qsTr("No scheduled tasks");
                        }
                        color: tasks.foreground
                        font.pixelSize: 13
                        font.weight: Font.Medium
                    }

                    Label {
                        Layout.fillWidth: true
                        visible: text.length > 0
                        text: {
                            if (environment.modelData.status !== "ready") return environment.modelData.message ?? "";
                            return environment.modelData.linkMissing
                                ? qsTr("This task no longer exists or is outside the selected project scope.")
                                : qsTr("No tasks match this environment and project selection.");
                        }
                        color: tasks.muted
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                    }
                }

                ShellButton {
                    objectName: "reconnect"
                    visible: environment.modelData.status === "disconnected"
                    text: qsTr("Reconnect")
                    onClicked: Shell.dispatch("connections.open")
                }
            }

            Repeater {
                model: environment.modelData.tasks

                delegate: Task {
                    environmentId: environment.modelData.id
                }
            }
        }
    }

    ScheduledTaskEditor {}
}
