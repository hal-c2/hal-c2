pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The maintenance settings: which repositories it maintains, when it runs,
// what a run covers and does, the agent and model that runs it, what becomes
// of its branch, and its prompt with each repository's own instructions. The
// agents, their models and the repositories come from the plugin's `settings`
// call; everything is saved together, and what the plugin refuses stays
// unsaved with its reason.
ColumnLayout {
    id: settings

    property var plugin
    // As the MC has them, and as the page shows them.
    property var saved: ({})
    property var values: ({})
    property var providers: []
    // The repositories of this MC's GitHub projects, to maintain by picking.
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

    function toggleRepository(repository) {
        const followed = settings.followed.slice();
        const at = followed.indexOf(repository);
        if (at >= 0)
            followed.splice(at, 1);
        else
            followed.push(repository);
        settings.set("repositories", followed);
    }

    function toggleCategory(category) {
        const picked = (settings.values.categories ?? []).slice();
        const at = picked.indexOf(category);
        if (at >= 0)
            picked.splice(at, 1);
        else
            picked.push(category);
        settings.set("categories", picked);
    }

    // A repository's own instructions; empty ones are not kept.
    function setInstructions(repository, text) {
        const instructions = Object.assign({}, settings.values.instructions ?? {});
        if (text.trim().length > 0)
            instructions[repository] = text;
        else
            delete instructions[repository];
        settings.set("instructions", instructions);
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

    objectName: "maintenanceSettings"
    width: parent ? parent.width : implicitWidth
    spacing: Theme.space.xl
    Component.onCompleted: load()

    // Any number of repositories, side by side.
    component Repositories: ShellChoice {
        Layout.fillWidth: true
        multiple: true
        optionName: "maintenanceSetting:repository:"
        options: settings.choices
        value: settings.followed
        onPicked: value => settings.toggleRepository(value)
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
        id: form

        // The agent it runs, and the model it runs on: the picked one, else the agent's default.
        readonly property var provider: settings.providers.find(each => each.instanceId === settings.values.provider) ?? null
        readonly property var models: provider?.models ?? []
        readonly property var modelEntry: models.find(each => each.slug === settings.values.model) ?? models.find(each => each.isDefault) ?? models[0] ?? null

        Layout.fillWidth: true
        visible: settings.loaded
        spacing: Theme.space.xl

        SettingsHeading {
            text: qsTr("What it maintains")
        }

        SettingsField {
            title: qsTr("Repositories")
            description: qsTr("A run works in the repository's own project on this MC.")

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
            title: qsTr("Categories")

            ShellChoice {
                Layout.fillWidth: true
                multiple: true
                optionName: "maintenanceSetting:category:"
                options: [
                    {
                        value: "deps",
                        label: qsTr("Dependencies")
                    },
                    {
                        value: "security-alerts",
                        label: qsTr("Security alerts")
                    },
                    {
                        value: "docs-drift",
                        label: qsTr("Docs drift")
                    },
                    {
                        value: "coverage-gaps",
                        label: qsTr("Coverage gaps")
                    }
                ]
                value: settings.values.categories ?? []
                onPicked: value => settings.toggleCategory(value)
            }
        }

        SettingsField {
            title: qsTr("Security advisories only")
            description: qsTr("Only fix open security advisories, each with the smallest safe upgrade, and leave the rest.")

            control: ShellSwitch {
                objectName: "maintenanceSetting:securityOnly"
                checked: settings.values.securityOnly === true
                Accessible.name: qsTr("Security advisories only")
                onToggled: settings.set("securityOnly", checked)
            }
        }

        SettingsField {
            title: qsTr("Mode")
            description: qsTr("Report only changes nothing and says what it would do. Fix works on a maintenance/<date> branch in a new worktree, never on the default branch.")

            ShellChoice {
                objectName: "maintenanceSetting:mode"
                Layout.fillWidth: true
                options: [
                    {
                        value: "fix",
                        label: qsTr("Fix, on a maintenance branch")
                    },
                    {
                        value: "report",
                        label: qsTr("Report only")
                    }
                ]
                value: settings.values.mode ?? "fix"
                onPicked: value => settings.set("mode", value)
            }
        }

        SettingsHeading {
            text: qsTr("When it runs")
        }

        SettingsField {
            title: qsTr("Run")
            description: qsTr("A run missed while the MC was off starts once when it is back.")

            ShellChoice {
                objectName: "maintenanceSetting:schedule"
                Layout.fillWidth: true
                options: [
                    {
                        value: "manual",
                        label: qsTr("Only when I ask")
                    },
                    {
                        value: "daily",
                        label: qsTr("Every day")
                    },
                    {
                        value: "weekly",
                        label: qsTr("Every week")
                    }
                ]
                value: settings.values.schedule ?? "weekly"
                onPicked: value => settings.set("schedule", value)
            }
        }

        SettingsField {
            title: qsTr("Day of the week")
            visible: settings.values.schedule === "weekly"

            ShellChoice {
                objectName: "maintenanceSetting:weekday"
                Layout.fillWidth: true
                options: [
                    {
                        value: "monday",
                        label: qsTr("Monday")
                    },
                    {
                        value: "tuesday",
                        label: qsTr("Tuesday")
                    },
                    {
                        value: "wednesday",
                        label: qsTr("Wednesday")
                    },
                    {
                        value: "thursday",
                        label: qsTr("Thursday")
                    },
                    {
                        value: "friday",
                        label: qsTr("Friday")
                    },
                    {
                        value: "saturday",
                        label: qsTr("Saturday")
                    },
                    {
                        value: "sunday",
                        label: qsTr("Sunday")
                    }
                ]
                value: settings.values.weekday ?? "monday"
                onPicked: value => settings.set("weekday", value)
            }
        }

        SettingsField {
            title: qsTr("At")
            description: qsTr("HH:MM, in this MC's local time.")
            visible: settings.values.schedule !== "manual"

            ShellTextField {
                objectName: "maintenanceSetting:time"
                implicitWidth: 100
                text: settings.values.time ?? ""
                onTextEdited: settings.set("time", text)
            }
        }

        SettingsField {
            title: qsTr("Runs at once")

            ShellSpinBox {
                objectName: "maintenanceSetting:concurrency"
                editable: true
                from: 1
                to: 999999999
                value: settings.values.concurrency ?? 1
                Accessible.name: qsTr("Runs at once")
                onValueModified: settings.set("concurrency", value)
                onValueTyped: typed => settings.set("concurrency", typed)
            }
        }

        SettingsHeading {
            text: qsTr("The agent")
        }

        SettingsField {
            title: qsTr("Agent and model")

            RowLayout {
                spacing: Theme.space.sm

                ShellComboBox {
                    objectName: "maintenanceSetting:provider"
                    outline: true
                    implicitWidth: 200
                    model: settings.providers.map(each => each.name)
                    currentIndex: settings.providers.findIndex(each => each.instanceId === settings.values.provider)
                    displayText: currentIndex >= 0 ? currentText : (settings.values.provider ?? "")
                    Accessible.name: qsTr("Agent")
                    onActivated: index => {
                        settings.set("provider", settings.providers[index].instanceId);
                        settings.set("model", "");
                        settings.set("modelOptions", {});
                    }
                }

                ShellComboBox {
                    objectName: "maintenanceSetting:model"
                    outline: true
                    implicitWidth: 240
                    model: [qsTr("Its default model")].concat(form.models.map(each => each.name || each.slug))
                    currentIndex: (settings.values.model ?? "") === "" ? 0 : form.models.findIndex(each => each.slug === settings.values.model) + 1
                    displayText: currentIndex >= 0 ? currentText : settings.values.model
                    Accessible.name: qsTr("Model")
                    onActivated: index => {
                        settings.set("model", index === 0 ? "" : form.models[index - 1].slug);
                        settings.set("modelOptions", {});
                    }
                }
            }
        }

        // What the chosen model offers besides itself: its reasoning effort first of all.
        Repeater {
            model: form.modelEntry?.options ?? []

            delegate: SettingsField {
                id: option

                required property var modelData
                readonly property var chosen: settings.values.modelOptions ?? {}

                function pick(value) {
                    const options = Object.assign({}, option.chosen);
                    if (value === undefined)
                        delete options[option.modelData.id];
                    else
                        options[option.modelData.id] = value;
                    settings.set("modelOptions", options);
                }

                objectName: "maintenanceSetting:modelOption:" + modelData.id
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
            description: qsTr("A fix run edits and commits in its own worktree; it never pushes.")

            ShellChoice {
                objectName: "maintenanceSetting:runtimeMode"
                Layout.fillWidth: true
                options: [
                    {
                        value: "approval-required",
                        label: qsTr("Ask before changes")
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
                value: settings.values.runtimeMode ?? "auto-accept-edits"
                onPicked: value => settings.set("runtimeMode", value)
            }
        }

        SettingsField {
            title: qsTr("Prompt")
            description: qsTr("{{repository}}, {{mode}}, {{categories}}, {{branch}}, {{base}}, {{date}} and {{skill}} are filled in. The rules every run keeps, and how to report, are added after it.")

            ShellTextArea {
                objectName: "maintenanceSetting:prompt"
                Layout.fillWidth: true
                Layout.preferredHeight: Math.max(120, implicitHeight)
                text: settings.values.prompt ?? ""
                Accessible.name: qsTr("Prompt")
                onTextChanged: if (activeFocus)
                    settings.set("prompt", text)
            }
        }

        SettingsField {
            title: qsTr("Per-repository instructions")
            description: qsTr("Added to that repository's prompt, such as which checks to run or what to leave alone.")
            visible: settings.followed.length > 0

            Repeater {
                model: settings.followed

                delegate: ColumnLayout {
                    id: own

                    required property string modelData

                    Layout.fillWidth: true
                    spacing: Theme.space.xs

                    Label {
                        Layout.fillWidth: true
                        color: settings.muted
                        wrapMode: Text.Wrap
                        font.pixelSize: Theme.type.meta.size
                        text: own.modelData
                    }

                    ShellTextArea {
                        objectName: "maintenanceSetting:instructions:" + own.modelData
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.max(60, implicitHeight)
                        text: (settings.values.instructions ?? {})[own.modelData] ?? ""
                        Accessible.name: qsTr("Instructions for %1").arg(own.modelData)
                        onTextChanged: if (activeFocus)
                            settings.setInstructions(own.modelData, text)
                    }
                }
            }
        }

        SettingsHeading {
            text: qsTr("What becomes of a run")
        }

        SettingsField {
            title: qsTr("Publishing")
            description: qsTr("What happens to a fix run's branch once its agent reports.")

            ShellChoice {
                objectName: "maintenanceSetting:publishing"
                Layout.fillWidth: true
                options: [
                    {
                        value: "local",
                        label: qsTr("Keep in HAL-C2")
                    },
                    {
                        value: "draft",
                        label: qsTr("Wait for me to open the pull request")
                    },
                    {
                        value: "automatic",
                        label: qsTr("Open the pull request automatically")
                    }
                ]
                value: settings.values.publishing ?? "draft"
                onPicked: value => settings.set("publishing", value)
            }
        }

        Label {
            objectName: "maintenanceRefusal"
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
                objectName: "maintenanceSave"
                primary: true
                text: settings.saving ? qsTr("Saving…") : qsTr("Save")
                enabled: settings.dirty && !settings.saving
                onClicked: settings.save()
            }
        }
    }
}
