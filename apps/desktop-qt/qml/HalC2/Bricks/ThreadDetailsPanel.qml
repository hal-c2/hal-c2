pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The thread details column beside a thread (threadPanel.toggle, the header's
// info button): where the thread runs, its checkout, and the threads it came
// from or started, from the `details` of the published `panel`. A related
// thread opens on click. Changing the checkout or branch stays with the
// composer's context strip.
//
//   ThreadDetailsPanel { details: Shell.state.panel?.details ?? null }
Rectangle {
    id: root

    property var details: null
    // The thread's project's actions (ProjectActionsController).
    readonly property var actions: details !== null ? Shell.state.projectActions ?? null : null
    readonly property string environmentId: details !== null ? Shell.state.workspace?.activeEnvironmentId ?? "" : ""

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color borderColor: Theme.palette.color("border", "#27272a")

    objectName: "threadDetailsPanel"
    implicitWidth: 280
    color: Theme.palette.color("surface", "#0f0f11")

    Rectangle {
        width: 1
        height: parent.height
        color: root.borderColor
    }

    component Heading: Text {
        Layout.topMargin: 10
        color: root.muted
        font.pixelSize: Math.round(11 * Theme.fontScale)
        font.weight: Font.Medium
        font.capitalization: Font.AllUppercase
    }

    component Fact: RowLayout {
        property string icon
        property string value
        property color tint: root.foreground

        Layout.fillWidth: true
        visible: value.length > 0
        spacing: 8

        ShellIcon {
            name: parent.icon
            size: 14
            color: root.muted
        }
        Text {
            Layout.fillWidth: true
            text: parent.value
            elide: Text.ElideMiddle
            color: parent.tint
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }
    }

    RowLayout {
        id: header

        x: 12
        y: 8
        width: parent.width - 20

        Text {
            Layout.fillWidth: true
            text: qsTr("Thread details")
            color: root.foreground
            font.pixelSize: Math.round(13 * Theme.fontScale)
            font.weight: Font.Medium
        }
        ShellButton {
            objectName: "threadDetailsClose"
            subtle: true
            iconName: "x"
            Accessible.name: qsTr("Close thread details")
            onClicked: Shell.dispatch("threadPanel.toggle")
        }
    }

    Flickable {
        anchors.top: header.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        clip: true
        contentHeight: facts.implicitHeight + 16
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: facts

            x: 12
            width: parent.width - 24
            spacing: 6

            Heading {
                text: qsTr("Workspace")
            }
            Fact {
                objectName: "threadDetailsEnvironment"
                icon: Shell.state.environmentIcons?.[root.environmentId]?.icon ?? "server"
                value: root.details ? (root.details.online ? root.details.environment : qsTr("%1 (unreachable)").arg(root.details.environment)) : ""
                tint: root.details?.online === false ? Theme.palette.color("warning", "#f59e0b") : root.foreground
            }
            RowLayout {
                Layout.fillWidth: true
                visible: (root.details?.project ?? "").length > 0
                spacing: 8

                ProjectIcon {
                    objectName: "threadDetailsProjectIcon"
                    size: 14
                    icon: Shell.state.projectIcons?.[Shell.state.projectActions?.projectKey ?? ""] ?? null
                }
                Text {
                    Layout.fillWidth: true
                    text: root.details?.project ?? ""
                    elide: Text.ElideMiddle
                    color: root.foreground
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }
            }
            Fact {
                objectName: "threadDetailsCheckout"
                icon: root.details?.checkout === "Worktree" ? "git-fork" : "folder"
                value: root.details ? root.details.checkout + " · " + root.details.folder : ""
            }
            Fact {
                objectName: "threadDetailsBranch"
                icon: "git-branch"
                value: root.details?.branch ?? ""
            }

            ShellButton {
                id: openWorkspace

                readonly property var editor: (Shell.state.workspace?.editors ?? []).find(candidate => candidate.id === Shell.state.workspace?.preferredEditorId) ?? null

                objectName: "threadDetailsOpenEditor"
                visible: root.details !== null && editor !== null
                subtle: true
                iconName: "external-link"
                text: qsTr("Open in %1").arg(editor?.label ?? "")
                onClicked: Shell.dispatch("workspace.openInEditor", {})
            }

            Heading {
                visible: root.actions !== null
                text: qsTr("Actions")
            }
            Repeater {
                model: root.actions?.scripts ?? []

                delegate: RowLayout {
                    id: action

                    required property var modelData

                    Layout.fillWidth: true
                    spacing: 4

                    ShellButton {
                        objectName: "threadDetailsAction-" + action.modelData.id
                        Layout.fillWidth: true
                        subtle: true
                        iconName: "play"
                        text: action.modelData.setup ? qsTr("%1 (setup)").arg(action.modelData.name) : action.modelData.name
                        Accessible.name: qsTr("Run %1").arg(action.modelData.name)
                        onClicked: Shell.dispatch("workspace.runScript", {
                            scriptId: action.modelData.id
                        })
                    }
                    Text {
                        visible: text.length > 0
                        text: action.modelData.shortcut
                        color: root.muted
                        font.pixelSize: Math.round(11 * Theme.fontScale)
                    }
                    ShellButton {
                        objectName: "threadDetailsActionEdit-" + action.modelData.id
                        subtle: true
                        iconName: "settings"
                        Accessible.name: qsTr("Edit %1").arg(action.modelData.name)
                        onClicked: Shell.dispatch("projectActions.edit", {
                            scriptId: action.modelData.id
                        })
                    }
                }
            }
            Text {
                objectName: "threadDetailsProjectFileProblem"
                Layout.fillWidth: true
                visible: root.actions?.file === "invalid"
                text: qsTr("hal-c2.json is invalid, so its actions are not offered.")
                color: Theme.palette.color("warning", "#f59e0b")
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }
            Repeater {
                model: root.actions?.imports ?? []

                delegate: ShellButton {
                    required property var modelData

                    objectName: "threadDetailsImport-" + modelData.name
                    Layout.fillWidth: true
                    subtle: true
                    iconName: "plus"
                    text: qsTr("Import %1 from hal-c2.json").arg(modelData.name)
                    onClicked: Shell.dispatch("projectActions.import", {
                        name: modelData.name
                    })
                }
            }
            ShellButton {
                objectName: "threadDetailsAddAction"
                visible: root.actions !== null
                subtle: true
                iconName: "plus"
                text: qsTr("Add action")
                onClicked: Shell.dispatch("projectActions.add")
            }

            Heading {
                visible: (root.details?.relations ?? []).length > 0
                text: qsTr("Related threads")
            }
            Repeater {
                model: root.details?.relations ?? []

                delegate: ItemDelegate {
                    id: relation

                    required property var modelData

                    objectName: "threadDetailsRelation"
                    Layout.fillWidth: true
                    implicitHeight: 40
                    hoverEnabled: true
                    Accessible.name: modelData.relation + " " + modelData.title
                    onClicked: Shell.dispatch("rightPanel.openThread", {
                        threadKey: modelData.threadKey
                    })
                    background: Rectangle {
                        radius: 6
                        color: relation.hovered || relation.visualFocus ? Theme.palette.color("surfaceRaised", "#1f1f24") : "transparent"
                    }
                    contentItem: ColumnLayout {
                        spacing: 1

                        Text {
                            Layout.fillWidth: true
                            text: relation.modelData.relation
                            color: root.muted
                            font.pixelSize: Math.round(11 * Theme.fontScale)
                        }
                        Text {
                            Layout.fillWidth: true
                            text: relation.modelData.title
                            elide: Text.ElideRight
                            color: root.foreground
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }
                    }
                }
            }
        }
    }
}
