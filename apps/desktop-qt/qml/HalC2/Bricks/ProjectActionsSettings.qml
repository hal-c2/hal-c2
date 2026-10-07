pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → Project, Actions (ProjectActionsController's `projectActions` in settings):
// the actions every project on the selected environments starts with, or the
// picked project's own list, with adding one, importing hal-c2.json's, and
// resetting a project to its environment's defaults.
ColumnLayout {
    id: section

    readonly property var model: Shell.state.projectActions?.settings === true ? Shell.state.projectActions : null
    readonly property var actions: model?.scripts ?? []
    readonly property bool editable: (Shell.state.settingsScope?.editable ?? false) && (model?.available ?? false)
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color warning: Theme.palette.color("warning", "#fbbf24")

    objectName: "projectActions"
    Layout.fillWidth: true
    visible: model !== null
    spacing: 8

    component Note: Label {
        Layout.fillWidth: true
        color: Theme.palette.color("textMuted", "#a1a1aa")
        font.pixelSize: Math.round(12 * Theme.fontScale)
        wrapMode: Text.Wrap
    }

    component Tag: Label {
        color: Theme.palette.color("textMuted", "#a1a1aa")
        font.pixelSize: Math.round(11 * Theme.fontScale)
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 12
        spacing: 8

        Label {
            Layout.fillWidth: true
            text: qsTr("Actions")
            color: section.foreground
            font.pixelSize: Math.round(14 * Theme.fontScale)
            font.weight: Font.DemiBold
        }

        ShellButton {
            objectName: "resetActions"
            visible: section.model?.own ?? false
            enabled: section.editable
            subtle: true
            text: qsTr("Use the environment's actions")
            onClicked: Shell.dispatch("projectActions.reset")
        }
    }

    Note {
        text: section.model?.project ? qsTr("Commands that run in this project's checkout or its worktree.")
                                     : qsTr("Commands every project on the selected environments starts with.")
    }

    Note {
        objectName: "mixedActions"
        visible: section.model?.mixed ?? false
        color: section.warning
        text: qsTr("Different actions across environments. Choose one environment to edit its list. Adding an action here adds it on every selected environment.")
    }

    Note {
        objectName: "noActions"
        visible: section.actions.length === 0
        text: qsTr("No actions configured.")
    }

    Repeater {
        model: section.actions

        delegate: RowLayout {
            id: action

            required property var modelData

            objectName: "action:" + modelData.id
            Layout.fillWidth: true
            spacing: 8

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                RowLayout {
                    spacing: 6

                    Label {
                        text: action.modelData.name
                        color: section.foreground
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                    }

                    Tag {
                        objectName: "setup"
                        visible: action.modelData.setup
                        text: qsTr("setup")
                    }

                    Tag {
                        objectName: "preview"
                        visible: action.modelData.preview
                        text: qsTr("preview · desktop only")
                    }
                }

                Label {
                    Layout.fillWidth: true
                    text: action.modelData.command
                    color: section.muted
                    font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    elide: Text.ElideRight
                }
            }

            ShellButton {
                objectName: "remove"
                subtle: true
                enabled: section.editable
                text: qsTr("Remove")
                Accessible.name: qsTr("Remove %1").arg(action.modelData.name)
                onClicked: Shell.dispatch("projectActions.delete", { scriptId: action.modelData.id })
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 8

        ShellTextField {
            id: name

            objectName: "actionName"
            Layout.preferredWidth: 160
            placeholderText: qsTr("Name")
            Accessible.name: qsTr("Action name")
        }

        ShellTextField {
            id: command

            objectName: "actionCommand"
            Layout.fillWidth: true
            placeholderText: qsTr("Command")
            Accessible.name: qsTr("Action command")
        }

        ShellButton {
            objectName: "addAction"
            enabled: name.text.trim().length > 0 && command.text.trim().length > 0
            text: qsTr("Add action")
            onClicked: {
                Shell.dispatch("projectActions.add", { name: name.text, command: command.text });
                name.text = "";
                command.text = "";
            }
        }
    }

    Repeater {
        model: section.model?.imports ?? []

        delegate: RowLayout {
            id: found

            required property var modelData

            Layout.fillWidth: true
            spacing: 8

            Note {
                text: qsTr("%1 (%2) is declared in hal-c2.json.").arg(found.modelData.name).arg(found.modelData.command)
            }

            ShellButton {
                objectName: "import:" + found.modelData.name
                subtle: true
                enabled: section.editable
                text: qsTr("Import")
                Accessible.name: qsTr("Import %1 from hal-c2.json").arg(found.modelData.name)
                onClicked: Shell.dispatch("projectActions.import", { name: found.modelData.name })
            }
        }
    }

    Note {
        objectName: "invalidFile"
        visible: section.model?.file === "invalid"
        color: section.warning
        text: qsTr("hal-c2.json is invalid. A hal-c2.json exists in this checkout but fails to parse, so every action and icon it declares is ignored. Check the JSON syntax and icon values.")
    }
}
