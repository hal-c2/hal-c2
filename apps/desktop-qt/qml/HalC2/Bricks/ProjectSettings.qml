import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → Project, natively (ProjectSettingsController's `projectSettings`):
// the picked project's name, icon, checkouts and removal, then how new threads
// start there, or with no project picked, on the selected environments.
SettingsPage {
    id: page

    readonly property var state: Shell.state.projectSettings ?? null
    readonly property bool ready: state?.status === "ready"
    readonly property bool editable: Shell.state.settingsScope?.editable ?? false
    readonly property bool projectScope: (Shell.state.settingsScope?.kind ?? "all") === "project"
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color warning: Theme.palette.color("warning", "#fbbf24")

    function send(name, payload) {
        Shell.dispatch("projectSettings." + name, payload ?? {});
    }

    objectName: "projectSettings"
    title: qsTr("Project")

    component Heading: Label {
        color: page.muted
        font.pixelSize: Math.round(12 * Theme.fontScale)
        font.weight: Font.DemiBold
    }

    component Caption: Label {
        Layout.fillWidth: true
        color: page.muted
        font.pixelSize: Math.round(12 * Theme.fontScale)
        wrapMode: Text.Wrap
    }

    // A row: its title, what it does, and its control on the right.
    component Row: RowLayout {
        id: row

        property string title
        property string description
        property bool mixed: false
        property string resetKey: ""
        property bool resettable: false
        default property alias control: controls.data

        Layout.fillWidth: true
        spacing: 12

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            RowLayout {
                spacing: 6

                Label {
                    text: row.title
                    color: page.foreground
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                    font.weight: Font.Medium
                }

                ShellButton {
                    objectName: "reset"
                    visible: row.resetKey.length > 0 && row.resettable && page.editable
                    subtle: true
                    text: page.projectScope ? qsTr("Inherit") : qsTr("Reset")
                    onClicked: page.send("reset", { key: row.resetKey })
                }
            }

            Label {
                objectName: "mixed"
                visible: row.mixed
                text: qsTr("Mixed across selected machines")
                color: page.warning
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }

            Caption {
                visible: text.length > 0
                text: row.description
            }
        }

        RowLayout {
            id: controls
            spacing: 8
        }
    }

    // How new threads start: one of a default's options.
    component Choice: Row {
        id: choice

        property string name
        readonly property var entry: page.state?.[name] ?? null

        objectName: name
        mixed: entry?.mixed ?? false
        resetKey: name
        resettable: entry?.resettable ?? false

        ShellComboBox {
            objectName: "control"
            enabled: page.editable
            outline: true
            implicitWidth: 200
            model: (choice.entry?.options ?? []).map(option => option.label)
            currentIndex: (choice.entry?.options ?? []).findIndex(option => option.value === choice.entry?.value)
            displayText: choice.entry?.label ?? ""
            Accessible.name: choice.title
            onActivated: index => page.send(choice.name, { value: choice.entry.options[index].value })
        }
    }

    SettingsScopeSentence {}

    Caption {
        objectName: "message"
        visible: text.length > 0
        text: page.state?.message ?? ""
    }

    ColumnLayout {
        objectName: "identity"
        visible: page.ready
        Layout.fillWidth: true
        spacing: 12

        Heading { text: qsTr("Project") }

        Row {
            objectName: "name"
            title: qsTr("Name")
            description: qsTr("How the project shows in the sidebar, on every checkout in this scope.")

            TextField {
                id: name

                objectName: "control"
                implicitWidth: 240
                enabled: page.editable
                text: page.state?.name ?? ""
                selectByMouse: true
                Accessible.name: qsTr("Project name")
                onEditingFinished: {
                    if (text.trim() !== (page.state?.name ?? "")) page.send("rename", { title: text });
                    else text = Qt.binding(() => page.state?.name ?? "");
                }
            }
        }

        Row {
            objectName: "icon"
            title: qsTr("Icon")
            description: page.state?.icon?.custom ? qsTr("Current: %1").arg(page.state.icon.label)
                                                  : qsTr("Automatic, from the project's favicon when it has one.")

            ProjectIcon {
                objectName: "preview"
                size: 20
                icon: Shell.state.projectIcons?.[page.state?.checkouts?.[0]?.key ?? ""] ?? null
            }

            ShellButton {
                objectName: "choose"
                enabled: page.editable
                subtle: true
                text: qsTr("Choose…")
                onClicked: Shell.dispatch("projectIcon.open", {
                    projectKey: page.state?.checkouts?.[0]?.key ?? "",
                    name: page.state?.name ?? ""
                })
            }

            TextField {
                objectName: "emoji"
                implicitWidth: 64
                enabled: page.editable
                text: page.state?.icon?.emoji ?? ""
                placeholderText: qsTr("Emoji")
                Accessible.name: qsTr("Project icon emoji")
                onEditingFinished: {
                    if (text.trim().length > 0 && text.trim() !== (page.state?.icon?.emoji ?? "")) page.send("icon", { emoji: text.trim() });
                }
            }

            ShellButton {
                objectName: "automatic"
                visible: page.state?.icon?.custom ?? false
                enabled: page.editable
                subtle: true
                text: qsTr("Use automatic")
                onClicked: page.send("icon", {})
            }
        }

        ColumnLayout {
            objectName: "checkouts"
            visible: (page.state?.checkouts ?? []).length > 1
            Layout.fillWidth: true
            spacing: 6

            Heading { text: qsTr("Checkouts") }

            Repeater {
                model: page.state?.checkouts ?? []

                delegate: RowLayout {
                    required property var modelData
                    objectName: "checkout:" + modelData.key
                    Layout.fillWidth: true
                    spacing: 8

                    Label {
                        text: modelData.environment
                        color: page.foreground
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                        font.weight: Font.Medium
                    }

                    Caption {
                        text: modelData.path
                        font.family: "monospace"
                        elide: Text.ElideMiddle
                        wrapMode: Text.NoWrap
                    }

                    ShellButton {
                        objectName: "remove"
                        enabled: page.editable
                        subtle: true
                        text: qsTr("Remove")
                        Accessible.name: qsTr("Remove the checkout on %1").arg(modelData.environment)
                        onClicked: page.send("remove", { key: modelData.key })
                    }
                }
            }
        }

        Row {
            objectName: "removal"
            title: page.state?.removal?.title ?? ""
            description: page.state?.removal?.description ?? ""

            ShellButton {
                objectName: "control"
                enabled: page.editable
                tint: Theme.palette.color("error", "#ef4444")
                text: page.state?.removal?.button ?? ""
                onClicked: page.send("remove")
            }
        }
    }

    Heading { text: qsTr("New threads") }

    Caption {
        visible: !(page.state?.available ?? false)
        text: qsTr("Connect an environment in this scope to change how its threads start.")
    }

    Row {
        objectName: "model"
        title: qsTr("Default model")
        description: page.state?.model?.none ? qsTr("No provider is ready on this environment.")
                                             : qsTr("Automatic uses the provider's own default.")
        mixed: page.state?.model?.mixed ?? false
        resetKey: "model"
        resettable: page.state?.model?.resettable ?? false

        ShellComboBox {
            objectName: "control"
            enabled: page.editable && (page.state?.available ?? false)
            outline: true
            implicitWidth: 260
            readonly property var models: page.state?.model?.models ?? []
            model: [qsTr("Automatic")].concat(models.map(model => model.label))
            currentIndex: page.state?.model?.automatic ? 0 : models.findIndex(model => model.key === page.state?.model?.value) + 1
            displayText: page.state?.model?.label ?? ""
            Accessible.name: qsTr("Default model")
            onActivated: index => page.send("model", { key: index === 0 ? "" : models[index - 1].key })
        }
    }

    // Where the default model comes from: the layers it resolves through, and
    // from an environment's view the projects that override it.
    ColumnLayout {
        id: sources

        readonly property var inheritance: page.state?.model?.inheritance ?? null

        objectName: "modelSources"
        Layout.fillWidth: true
        spacing: 4

        ShellButton {
            objectName: "inspect"
            subtle: true
            text: sources.inheritance === null ? qsTr("Where this comes from") : qsTr("Hide where this comes from")
            onClicked: page.send("inspect", { key: sources.inheritance === null ? "model" : "" })
        }

        Repeater {
            model: sources.inheritance?.layers ?? []

            delegate: Caption {
                required property var modelData

                objectName: "layer:" + modelData.key
                color: modelData.effective ? page.foreground : page.muted
                font.weight: modelData.effective ? Font.DemiBold : Font.Normal
                text: modelData.effective ? qsTr("%1: %2 (in effect)").arg(modelData.label).arg(modelData.value) : qsTr("%1: %2").arg(modelData.label).arg(modelData.value)
            }
        }

        Repeater {
            model: sources.inheritance?.overridingProjects ?? []

            delegate: RowLayout {
                id: overriding

                required property var modelData

                Layout.fillWidth: true
                spacing: 8

                Caption {
                    text: qsTr("%1 overrides it with %2.").arg(overriding.modelData.title).arg(overriding.modelData.value)
                }

                ShellButton {
                    objectName: "clear:" + overriding.modelData.projectId
                    subtle: true
                    enabled: page.editable
                    text: qsTr("Reset")
                    Accessible.name: qsTr("Reset the override of %1").arg(overriding.modelData.title)
                    onClicked: page.send("clearOverride", { environmentId: overriding.modelData.environmentId, projectId: overriding.modelData.projectId })
                }
            }
        }
    }

    Choice {
        name: "permissions"
        title: qsTr("Permissions")
        description: qsTr("What agents may do before asking.")
    }

    Choice {
        name: "workspace"
        title: qsTr("Workspace")
        description: qsTr("Where new threads work: the checkout itself or a fresh worktree.")
    }

    Choice {
        name: "submodules"
        title: qsTr("Worktree submodules")
        description: qsTr("Which submodules a new worktree checks out.")
    }

    ProjectActionsSettings {}

    Caption {
        objectName: "note"
        visible: text.length > 0
        text: page.state?.note ?? ""
    }
}
