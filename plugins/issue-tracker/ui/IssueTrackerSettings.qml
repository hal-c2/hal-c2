pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The issue tracker's settings: which repositories are the queue, and the
// agents that prioritise, ask for follow-up, summarise and implement, each
// with its model, access and prompt. The agents and their models come from
// the plugin's `settings` call; everything is saved together, and what the
// plugin refuses stays unsaved with its reason.
ColumnLayout {
    id: settings

    property var plugin
    // As the MC has them, and as the page shows them.
    property var saved: ({})
    property var values: ({})
    property var providers: []
    // The repositories of this MC's GitHub projects, to follow by picking.
    property var available: []
    property bool loaded: false
    property bool dirty: false
    property bool saving: false
    property string refusal: ""
    property string problem: ""
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("inkTertiary", "#a1a1aa")
    readonly property color errorColor: Theme.palette.color("errorForeground", "#ef4444")
    // Picked repositories that are no project here stay listed, so they can be
    // unticked rather than silently kept.
    readonly property var followed: values.repositories ?? []
    readonly property var choices: available.concat(followed.filter(repository => !available.includes(repository)))

    function load() {
        settings.plugin.call("settings", {}, (result, error) => {
            if (error) {
                settings.problem = error;
                return;
            }
            settings.problem = "";
            settings.saved = result.settings ?? {};
            settings.providers = result.providers ?? [];
            settings.available = result.repositories ?? [];
            settings.loaded = true;
            settings.reset();
        });
    }

    function reset() {
        settings.values = Object.assign({}, settings.saved);
        settings.dirty = false;
        settings.refusal = "";
    }

    function set(key, value) {
        const next = Object.assign({}, settings.values);
        next[key] = value;
        settings.values = next;
        settings.dirty = true;
    }

    // Changes `field` of an agent setting.
    function setAgent(role, field, value) {
        const agent = Object.assign({}, settings.values[role] ?? {});
        agent[field] = value;
        settings.set(role, agent);
    }

    function toggleRepository(repository) {
        const followed = settings.followed.slice();
        const at = followed.indexOf(repository);
        if (at >= 0)
            followed.splice(at, 1);
        else
            followed.push(repository);
        settings.set("repositories", followed);
    }

    function save() {
        settings.saving = true;
        settings.refusal = "";
        settings.plugin.saveSettings(settings.values, (result, error) => {
            settings.saving = false;
            if (error)
                settings.refusal = error;
            else
                settings.load();
        });
    }

    objectName: "issueTrackerSettings"
    width: parent ? parent.width : implicitWidth
    spacing: Theme.space.xl
    Component.onCompleted: load()

    // Any number of repositories, side by side; none picked follows them all.
    component Repositories: ShellChoice {
        Layout.fillWidth: true
        multiple: true
        optionName: "issueTrackerSetting:repository:"
        options: settings.choices
        value: settings.followed
        onPicked: value => settings.toggleRepository(value)
    }

    // An agent setting and its prompt: which agent, which of its models, the
    // model's options, how much it may do on its own, and what it is asked.
    component Agent: ColumnLayout {
        id: section

        property string role
        property string promptKey
        property string title
        property string promptHint
        property string accessHint
        readonly property var agent: settings.values[role] ?? {}
        readonly property var provider: settings.providers.find(each => each.instanceId === agent.provider) ?? null
        readonly property var models: provider?.models ?? []
        // The model it will run on: the picked one, else the agent's default.
        readonly property var modelEntry: models.find(each => each.slug === agent.model) ?? models.find(each => each.isDefault) ?? models[0] ?? null

        objectName: "issueTrackerAgent:" + role
        Layout.fillWidth: true
        spacing: Theme.space.lg

        SettingsHeading {
            text: section.title
        }

        SettingsField {
            title: qsTr("Agent and model")

            RowLayout {
                spacing: Theme.space.sm

                ShellComboBox {
                    objectName: "issueTrackerSetting:" + section.role + ":provider"
                    outline: true
                    implicitWidth: 200
                    model: settings.providers.map(each => each.name)
                    currentIndex: settings.providers.findIndex(each => each.instanceId === section.agent.provider)
                    displayText: currentIndex >= 0 ? currentText : (section.agent.provider ?? "")
                    Accessible.name: qsTr("Agent")
                    onActivated: index => {
                        const agent = Object.assign({}, section.agent, {
                            provider: settings.providers[index].instanceId,
                            model: "",
                            modelOptions: {}
                        });
                        settings.set(section.role, agent);
                    }
                }

                ShellComboBox {
                    objectName: "issueTrackerSetting:" + section.role + ":model"
                    outline: true
                    implicitWidth: 240
                    model: [qsTr("Its default model")].concat(section.models.map(each => each.name || each.slug))
                    currentIndex: (section.agent.model ?? "") === "" ? 0 : section.models.findIndex(each => each.slug === section.agent.model) + 1
                    displayText: currentIndex >= 0 ? currentText : section.agent.model
                    Accessible.name: qsTr("Model")
                    onActivated: index => {
                        const agent = Object.assign({}, section.agent, {
                            model: index === 0 ? "" : section.models[index - 1].slug,
                            modelOptions: {}
                        });
                        settings.set(section.role, agent);
                    }
                }
            }
        }

        // What the chosen model offers besides itself: its reasoning effort first of all.
        Repeater {
            model: section.modelEntry?.options ?? []

            delegate: SettingsField {
                id: option

                required property var modelData
                readonly property var chosen: section.agent.modelOptions ?? {}

                function pick(value) {
                    const options = Object.assign({}, option.chosen);
                    if (value === undefined)
                        delete options[option.modelData.id];
                    else
                        options[option.modelData.id] = value;
                    settings.setAgent(section.role, "modelOptions", options);
                }

                objectName: "issueTrackerSetting:" + section.role + ":modelOption:" + modelData.id
                title: modelData.label ?? modelData.id

                ShellChoice {
                    Layout.fillWidth: true
                    visible: option.modelData.type !== "boolean"
                    options: [
                        {
                            value: "",
                            label: qsTr("Its default")
                        }
                    ].concat((option.modelData.options ?? []).map(each => ({
                                value: each.id,
                                label: each.label ?? each.id
                            })))
                    value: option.chosen[option.modelData.id] ?? ""
                    onPicked: value => option.pick(value === "" ? undefined : value)
                }

                control: ShellSwitch {
                    visible: option.modelData.type === "boolean"
                    checked: option.chosen[option.modelData.id] === true
                    Accessible.name: option.title
                    onToggled: option.pick(checked)
                }
            }
        }

        SettingsField {
            title: qsTr("Access")
            description: section.accessHint

            ShellChoice {
                objectName: "issueTrackerSetting:" + section.role + ":runtimeMode"
                Layout.fillWidth: true
                options: [
                    {
                        value: "approval-required",
                        label: qsTr("Ask before acting")
                    },
                    {
                        value: "auto-accept-edits",
                        label: qsTr("Accept edits")
                    },
                    {
                        value: "auto",
                        label: qsTr("Auto")
                    },
                    {
                        value: "full-access",
                        label: qsTr("Full access")
                    }
                ]
                value: section.agent.runtimeMode ?? "approval-required"
                onPicked: value => settings.setAgent(section.role, "runtimeMode", value)
            }
        }

        SettingsField {
            title: qsTr("Prompt")
            description: section.promptHint

            ShellTextArea {
                objectName: "issueTrackerSetting:" + section.promptKey
                Layout.fillWidth: true
                Layout.preferredHeight: Math.max(120, implicitHeight)
                text: settings.values[section.promptKey] ?? ""
                Accessible.name: qsTr("%1 prompt").arg(section.title)
                onTextChanged: if (activeFocus)
                    settings.set(section.promptKey, text)
            }
        }
    }

    Label {
        Layout.fillWidth: true
        visible: !settings.loaded || settings.problem.length > 0
        text: settings.problem.length > 0 ? qsTr("The settings could not be read: %1").arg(settings.problem) : qsTr("Loading…")
        color: settings.problem.length > 0 ? settings.errorColor : settings.muted
        wrapMode: Text.Wrap
        font.pixelSize: Theme.type.body.size
    }

    ColumnLayout {
        Layout.fillWidth: true
        visible: settings.loaded
        spacing: Theme.space.xl

        SettingsHeading {
            text: qsTr("What it follows")
        }

        SettingsField {
            title: qsTr("Repositories")
            description: qsTr("The queue is the open issues of these. None picked follows every GitHub project on this MC. Its agents run in a repository's own project, and implementing needs its checkout.")

            Repositories {}

            Label {
                Layout.fillWidth: true
                color: settings.muted
                wrapMode: Text.Wrap
                font.pixelSize: Theme.type.meta.size
                visible: settings.choices.length === 0
                text: qsTr("No GitHub project is on this MC yet.")
            }
        }

        SettingsField {
            title: qsTr("Only issues labelled")
            description: qsTr("Empty to follow every open issue.")

            ShellTextField {
                objectName: "issueTrackerSetting:issueLabel"
                implicitWidth: 240
                text: settings.values.issueLabel ?? ""
                onTextEdited: settings.set("issueLabel", text)
            }
        }

        SettingsField {
            title: qsTr("Look at GitHub every (minutes)")

            ShellSpinBox {
                objectName: "issueTrackerSetting:pollMinutes"
                editable: true
                from: 1
                to: 999999999
                value: settings.values.pollMinutes ?? 10
                Accessible.name: qsTr("Look at GitHub every (minutes)")
                onValueModified: settings.set("pollMinutes", value)
                onValueTyped: typed => settings.set("pollMinutes", typed)
            }
        }

        Agent {
            role: "prioritising"
            promptKey: "prioritisePrompt"
            title: qsTr("Prioritising")
            promptHint: qsTr("{{repository}}, {{issues}}, {{count}} and {{today}} are filled in. How to report is added after it. Applying its proposal sets each issue's priority: label.")
            accessHint: qsTr("It reads the queue and reports; it changes nothing itself.")
        }

        Agent {
            role: "followingUp"
            promptKey: "followUpPrompt"
            title: qsTr("Asking for follow-up")
            promptHint: qsTr("{{repository}}, {{number}}, {{title}}, {{author}}, {{body}}, {{labels}}, {{url}} and {{today}} are filled in. How to report is added after it. Its drafted comment is posted only when you apply it.")
            accessHint: qsTr("It reads the issue and reports; it changes nothing itself.")
        }

        Agent {
            role: "summarising"
            promptKey: "summarisePrompt"
            title: qsTr("Summarising")
            promptHint: qsTr("{{repository}}, {{number}}, {{title}}, {{author}}, {{body}}, {{labels}}, {{url}}, {{others}} and {{today}} are filled in. How to report is added after it. Its summary is posted as a comment only when you apply it.")
            accessHint: qsTr("It reads the issue and reports; it changes nothing itself.")
        }

        Agent {
            role: "implementing"
            promptKey: "implementPrompt"
            title: qsTr("Implementing")
            promptHint: qsTr("{{repository}}, {{number}}, {{title}}, {{author}}, {{body}}, {{labels}}, {{url}} and {{today}} are filled in.")
            accessHint: qsTr("It works in a new worktree of the issue's project.")
        }

        Label {
            objectName: "issueTrackerRefusal"
            Layout.fillWidth: true
            visible: settings.refusal.length > 0
            text: qsTr("Not saved: %1").arg(settings.refusal)
            color: settings.errorColor
            wrapMode: Text.Wrap
            font.pixelSize: Theme.type.meta.size
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space.sm

            Item {
                Layout.fillWidth: true
            }

            ShellButton {
                subtle: true
                text: qsTr("Discard changes")
                enabled: settings.dirty && !settings.saving
                onClicked: settings.reset()
            }

            ShellButton {
                objectName: "issueTrackerSave"
                primary: true
                text: settings.saving ? qsTr("Saving…") : qsTr("Save")
                enabled: settings.dirty && !settings.saving
                onClicked: settings.save()
            }
        }
    }
}
