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
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color border: Theme.palette.color("border", "#27272a")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
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
    spacing: 22
    Component.onCompleted: load()

    component Heading: Label {
        Layout.fillWidth: true
        Layout.topMargin: 6
        color: settings.foreground
        font.pixelSize: Math.round(14 * Theme.fontScale)
        font.weight: Font.DemiBold
    }

    component Hint: Label {
        Layout.fillWidth: true
        visible: text.length > 0
        color: settings.muted
        wrapMode: Text.Wrap
        font.pixelSize: Math.round(12 * Theme.fontScale)
    }

    // A setting: its label, what it means, and its control below.
    component Field: ColumnLayout {
        id: field

        property string label
        property string hint
        default property alias content: controls.data

        Layout.fillWidth: true
        spacing: 6

        Label {
            text: field.label
            color: settings.foreground
            font.pixelSize: Math.round(13 * Theme.fontScale)
            font.weight: Font.Medium
        }

        Hint {
            text: field.hint
        }

        ColumnLayout {
            id: controls

            Layout.fillWidth: true
            spacing: 6
        }
    }

    // One of a few values, side by side.
    component Choice: Flow {
        id: choice

        property var options: []
        property var value
        signal picked(var value)

        Layout.fillWidth: true
        spacing: 6

        Repeater {
            model: choice.options

            delegate: Rectangle {
                id: option

                required property var modelData
                readonly property bool chosen: modelData.value === choice.value

                objectName: "choice:" + modelData.value
                implicitWidth: optionText.implicitWidth + 20
                implicitHeight: 28
                radius: Math.min(Theme.radius, 8)
                color: chosen ? Theme.palette.color("accentSurface", "#27272a") : "transparent"
                border.color: chosen || activeFocus ? Theme.palette.color("focus", "#3b82f6") : settings.border
                border.width: activeFocus ? 2 : 1
                activeFocusOnTab: true
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        choice.picked(modelData.value);
                        event.accepted = true;
                    }
                }
                Accessible.role: Accessible.RadioButton
                Accessible.name: optionText.text
                Accessible.checkable: true
                Accessible.checked: chosen
                Accessible.onPressAction: choice.picked(modelData.value)

                Text {
                    id: optionText

                    anchors.centerIn: parent
                    text: option.modelData.label
                    color: settings.foreground
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: choice.picked(option.modelData.value)
                }
            }
        }
    }

    // Any number of repositories, side by side.
    component Repositories: Flow {
        Layout.fillWidth: true
        spacing: 6

        Repeater {
            model: settings.choices

            delegate: Rectangle {
                id: pick

                required property string modelData
                readonly property bool chosen: settings.followed.includes(modelData)

                objectName: "maintenanceSetting:repository:" + modelData
                implicitWidth: pickText.implicitWidth + 20
                implicitHeight: 28
                radius: Math.min(Theme.radius, 8)
                color: chosen ? Theme.palette.color("accentSurface", "#27272a") : "transparent"
                border.color: chosen || activeFocus ? Theme.palette.color("focus", "#3b82f6") : settings.border
                border.width: activeFocus ? 2 : 1
                activeFocusOnTab: true
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        settings.toggleRepository(pick.modelData);
                        event.accepted = true;
                    }
                }
                Accessible.role: Accessible.CheckBox
                Accessible.name: pickText.text
                Accessible.checkable: true
                Accessible.checked: chosen
                Accessible.onPressAction: settings.toggleRepository(pick.modelData)

                Text {
                    id: pickText

                    anchors.centerIn: parent
                    text: pick.modelData
                    color: settings.foreground
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: settings.toggleRepository(pick.modelData)
                }
            }
        }
    }

    component Area: TextArea {
        Layout.fillWidth: true
        wrapMode: TextEdit.Wrap
        color: settings.foreground
        font.pixelSize: Math.round(13 * Theme.fontScale)
        background: Rectangle {
            radius: Math.min(Theme.radius, 8)
            color: Theme.palette.color("input", "#18181b")
            border.color: Theme.palette.color("border", "#27272a")
        }
    }

    Label {
        Layout.fillWidth: true
        visible: !settings.loaded || settings.problem.length > 0
        text: settings.problem.length > 0 ? qsTr("The settings could not be read: %1").arg(settings.problem) : qsTr("Loading…")
        color: settings.problem.length > 0 ? settings.errorColor : settings.muted
        wrapMode: Text.Wrap
        font.pixelSize: Math.round(13 * Theme.fontScale)
    }

    ColumnLayout {
        id: form

        // The agent it runs, and the model it runs on: the picked one, else the agent's default.
        readonly property var provider: settings.providers.find(each => each.instanceId === settings.values.provider) ?? null
        readonly property var models: provider?.models ?? []
        readonly property var modelEntry: models.find(each => each.slug === settings.values.model) ?? models.find(each => each.isDefault) ?? models[0] ?? null

        Layout.fillWidth: true
        visible: settings.loaded
        spacing: 22

        Heading {
            text: qsTr("What it maintains")
        }

        Field {
            label: qsTr("Repositories")
            hint: qsTr("A run works in the repository's own project on this MC.")

            Repositories {}

            Hint {
                visible: settings.choices.length === 0
                text: qsTr("No GitHub project is on this MC yet.")
            }
        }

        Field {
            label: qsTr("Categories")

            Flow {
                Layout.fillWidth: true
                spacing: 6

                Repeater {
                    model: [
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

                    delegate: Rectangle {
                        id: category

                        required property var modelData
                        readonly property bool chosen: (settings.values.categories ?? []).includes(modelData.value)

                        objectName: "maintenanceSetting:category:" + modelData.value
                        implicitWidth: categoryText.implicitWidth + 20
                        implicitHeight: 28
                        radius: Math.min(Theme.radius, 8)
                        color: chosen ? Theme.palette.color("accentSurface", "#27272a") : "transparent"
                        border.color: chosen || activeFocus ? Theme.palette.color("focus", "#3b82f6") : settings.border
                        border.width: activeFocus ? 2 : 1
                        activeFocusOnTab: true
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                settings.toggleCategory(category.modelData.value);
                                event.accepted = true;
                            }
                        }
                        Accessible.role: Accessible.CheckBox
                        Accessible.name: categoryText.text
                        Accessible.checkable: true
                        Accessible.checked: chosen
                        Accessible.onPressAction: settings.toggleCategory(category.modelData.value)

                        Text {
                            id: categoryText

                            anchors.centerIn: parent
                            text: category.modelData.label
                            color: settings.foreground
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: settings.toggleCategory(category.modelData.value)
                        }
                    }
                }
            }
        }

        Field {
            label: qsTr("Security advisories only")
            hint: qsTr("Only fix open security advisories, each with the smallest safe upgrade, and leave the rest.")

            Switch {
                objectName: "maintenanceSetting:securityOnly"
                checked: settings.values.securityOnly === true
                Accessible.name: qsTr("Security advisories only")
                onToggled: settings.set("securityOnly", checked)
            }
        }

        Field {
            label: qsTr("Mode")
            hint: qsTr("Report only changes nothing and says what it would do. Fix works on a maintenance/<date> branch in a new worktree, never on the default branch.")

            Choice {
                objectName: "maintenanceSetting:mode"
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

        Heading {
            text: qsTr("When it runs")
        }

        Field {
            label: qsTr("Run")
            hint: qsTr("A run missed while the MC was off starts once when it is back.")

            Choice {
                objectName: "maintenanceSetting:schedule"
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

        Field {
            label: qsTr("Day of the week")
            visible: settings.values.schedule === "weekly"

            Choice {
                objectName: "maintenanceSetting:weekday"
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

        Field {
            label: qsTr("At")
            hint: qsTr("HH:MM, in this MC's local time.")
            visible: settings.values.schedule !== "manual"

            ShellTextField {
                objectName: "maintenanceSetting:time"
                implicitWidth: 100
                text: settings.values.time ?? ""
                onTextEdited: settings.set("time", text)
            }
        }

        Field {
            label: qsTr("Runs at once")

            ShellTextField {
                objectName: "maintenanceSetting:concurrency"
                implicitWidth: 100
                inputMethodHints: Qt.ImhDigitsOnly
                validator: IntValidator {
                    bottom: 1
                }
                text: String(settings.values.concurrency ?? "")
                onTextEdited: if (acceptableInput)
                    settings.set("concurrency", Number(text))
            }
        }

        Heading {
            text: qsTr("The agent")
        }

        Field {
            label: qsTr("Agent and model")

            RowLayout {
                spacing: 8

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

            delegate: Field {
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
                label: modelData.label ?? modelData.id

                Choice {
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

                Switch {
                    visible: option.modelData.type === "boolean"
                    checked: option.chosen[option.modelData.id] === true
                    Accessible.name: option.label
                    onToggled: option.pick(checked)
                }
            }
        }

        Field {
            label: qsTr("Access")
            hint: qsTr("A fix run edits and commits in its own worktree; it never pushes.")

            Choice {
                objectName: "maintenanceSetting:runtimeMode"
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

        Field {
            label: qsTr("Prompt")
            hint: qsTr("{{repository}}, {{mode}}, {{categories}}, {{branch}}, {{base}}, {{date}} and {{skill}} are filled in. The rules every run keeps, and how to report, are added after it.")

            Area {
                objectName: "maintenanceSetting:prompt"
                Layout.preferredHeight: Math.max(120, implicitHeight)
                text: settings.values.prompt ?? ""
                Accessible.name: qsTr("Prompt")
                onTextChanged: if (activeFocus)
                    settings.set("prompt", text)
            }
        }

        Field {
            label: qsTr("Per-repository instructions")
            hint: qsTr("Added to that repository's prompt, such as which checks to run or what to leave alone.")
            visible: settings.followed.length > 0

            Repeater {
                model: settings.followed

                delegate: ColumnLayout {
                    id: own

                    required property string modelData

                    Layout.fillWidth: true
                    spacing: 4

                    Hint {
                        text: own.modelData
                    }

                    Area {
                        objectName: "maintenanceSetting:instructions:" + own.modelData
                        Layout.preferredHeight: Math.max(60, implicitHeight)
                        text: (settings.values.instructions ?? {})[own.modelData] ?? ""
                        Accessible.name: qsTr("Instructions for %1").arg(own.modelData)
                        onTextChanged: if (activeFocus)
                            settings.setInstructions(own.modelData, text)
                    }
                }
            }
        }

        Heading {
            text: qsTr("What becomes of a run")
        }

        Field {
            label: qsTr("Publishing")
            hint: qsTr("What happens to a fix run's branch once its agent reports.")

            Choice {
                objectName: "maintenanceSetting:publishing"
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
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

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
