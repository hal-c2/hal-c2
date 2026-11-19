import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// planner's settings: the agent that runs actions and where, each action with its
// prompt, following GitHub, and the Slack channel. The agents, the MC's projects
// and repositories, the plugin's own actions and the Slack channels come from the
// plugin's `settings` call; the GitHub boards and their date fields come later from
// `boards` and `boardFields`, which wait on gh. Everything is saved together, and
// what the plugin refuses stays unsaved with its reason.
ColumnLayout {
    id: settings

    property var plugin
    // As the MC has them, and as the page shows them.
    property var saved: ({})
    property var values: ({})
    property var providers: []
    property var projects: []
    // Repositories of the MC's projects, to suggest.
    property var offered: []
    // The plugin's own actions, by id, to reset a prompt to.
    property var defaultActions: ({})
    property var slackChannels: []
    property bool slackConnected: false
    // The open GitHub boards of the projects' owners, why some could not be listed,
    // and the date fields of the chosen board, or why they could not be read.
    property var boards: []
    property string boardProblem: ""
    property var dateFields: []
    property string dateFieldsProblem: ""
    property bool loaded: false
    property bool dirty: false
    // From a save until its settings are read back, so Save and Discard never work
    // from what was read before it.
    property bool saving: false
    // Counts reads of the settings; only the latest one lands.
    property int reads: 0
    property string refusal: ""
    property string problem: ""
    readonly property var watched: values.repositories ?? []
    readonly property string board: values.board ?? ""
    readonly property var provider: providers.find(each => each.instanceId === values.provider) ?? null
    readonly property var actions: values.actions ?? {}
    // Built-in actions in the plugin's order, then the user's own.
    readonly property var actionIds: {
        const builtin = Object.keys(defaultActions).filter(id => actions[id] !== undefined);
        return builtin.concat(Object.keys(actions).filter(id => !builtin.includes(id)));
    }
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("inkTertiary", "#a1a1aa")
    readonly property color errorColor: Theme.palette.color("errorForeground", "#ef4444")
    readonly property color warningColor: Theme.palette.color("warning", "#f59e0b")
    readonly property var modes: [
        { value: "approval-required", label: qsTr("Ask before acting") },
        { value: "auto-accept-edits", label: qsTr("Accept edits") },
        { value: "auto", label: qsTr("Auto") },
        { value: "full-access", label: qsTr("Full access") }
    ]
    readonly property string variables: qsTr("{{today}}, {{plan}}, {{items}}, {{project}} and {{item.id}}, {{item.title}}, {{item.notes}}, {{item.status}}, {{item.start}}, {{item.due}}, {{item.progress}}, {{item.owner}}, {{item.labels}}, {{item.issue}}, {{item.pullRequests}}, {{item.subtasks}} and {{item.after}} are filled in. How to report is added after it.")

    // Reads the saved settings and ends a save. Given `sent`, the values a save sent,
    // what the user changed since is kept as unsaved changes on top. A read answered
    // after a later one began is dropped: it may predate a save.
    function load(sent) {
        const read = ++settings.reads;
        settings.plugin.call("settings", {}, (result, error) => {
            if (read !== settings.reads)
                return;
            settings.saving = false;
            if (error) {
                settings.problem = error;
                return;
            }
            const edits = {};
            for (const key in sent ? settings.values : {}) {
                if (JSON.stringify(settings.values[key]) !== JSON.stringify(sent[key]))
                    edits[key] = settings.values[key];
            }
            settings.problem = "";
            settings.saved = result.settings ?? {};
            settings.providers = result.providers ?? [];
            settings.projects = result.projects ?? [];
            settings.offered = result.repositories ?? [];
            settings.defaultActions = result.defaultActions ?? {};
            settings.slackChannels = result.slackChannels ?? [];
            settings.slackConnected = result.slackConnected === true;
            settings.loaded = true;
            settings.reset();
            for (const key in edits)
                settings.set(key, edits[key]);
        });
    }

    function listBoards() {
        settings.plugin.call("boards", {}, (result, error) => {
            settings.boards = result?.boards ?? [];
            settings.boardProblem = error ? String(error) : (result?.problems ?? []).join(" ");
        });
    }

    // The chosen board's date fields; none, so they are typed in, until they are read,
    // and none with the reason when the MC cannot read them.
    function readDateFields() {
        const board = settings.board;
        settings.dateFields = [];
        settings.dateFieldsProblem = "";
        if (!/^[^/\s]+\/\d+$/.test(board.trim()))
            return;
        settings.plugin.call("boardFields", { board: board }, (result, error) => {
            if (board !== settings.board)
                return;
            settings.dateFields = error ? [] : (result?.dateFields ?? []);
            settings.dateFieldsProblem = error ? String(error) : "";
        });
    }

    // Typing a board reads its fields once the typing stops.
    onBoardChanged: boardFieldsTimer.restart()

    function reset() {
        settings.values = Object.assign({}, settings.saved);
        settings.dirty = false;
        settings.refusal = "";
    }

    // The entry of a combo whose first entry is "none" for `value`, the `key` of a row of
    // `rows` (or a row itself, with no key): -1 for one no longer offered, which the
    // combo shows by its value instead.
    function pickedAfterNone(rows, key, value) {
        if ((value ?? "") === "")
            return 0;
        const at = rows.findIndex(each => (key ? each[key] : each) === value);
        return at < 0 ? -1 : at + 1;
    }

    function set(key, value) {
        const next = Object.assign({}, settings.values);
        next[key] = value;
        settings.values = next;
        settings.dirty = true;
    }

    // One field of action `id`, or the whole action when `key` is empty and
    // `value` undefined to remove it.
    function setAction(id, key, value) {
        const next = Object.assign({}, settings.actions);
        if (key.length === 0 && value === undefined)
            delete next[id];
        else if (key.length === 0)
            next[id] = value;
        else
            next[id] = Object.assign({}, next[id], { [key]: value });
        settings.set("actions", next);
    }

    // Returns a built-in action's prompt to the plugin's, in the unsaved form.
    function resetPrompt(id) {
        settings.setAction(id, "prompt", settings.defaultActions[id]?.prompt ?? "");
    }

    function addAction() {
        let n = 1;
        while (settings.actions["custom" + n] !== undefined)
            n += 1;
        settings.setAction("custom" + n, "", { label: qsTr("New action"), scope: "item", kind: "action", apply: "propose", builtin: false, prompt: "" });
    }

    function watch(repository) {
        const name = repository.trim();
        if (name.length === 0 || settings.watched.some(each => each.toLowerCase() === name.toLowerCase()))
            return;
        settings.set("repositories", settings.watched.concat([name]));
    }

    function unwatch(repository) {
        settings.set("repositories", settings.watched.filter(each => each !== repository));
    }

    // The settings changed since they were read; the MC keeps the others as they are.
    function changes() {
        const changed = {};
        for (const key in settings.values) {
            if (JSON.stringify(settings.values[key]) !== JSON.stringify(settings.saved[key]))
                changed[key] = settings.values[key];
        }
        return changed;
    }

    // The form stays editable while it saves; the read-back keeps what was typed since.
    function save(values) {
        const sent = Object.assign({}, settings.values);
        settings.saving = true;
        settings.refusal = "";
        settings.plugin.saveSettings(values, (result, error) => {
            if (error) {
                settings.saving = false;
                settings.refusal = error;
            } else {
                // What took is the baseline until the read-back lands, and if it fails.
                settings.saved = Object.assign({}, settings.saved, values);
                settings.load(sent);
            }
        });
    }

    objectName: "plannerSettings"
    width: parent ? parent.width : implicitWidth
    spacing: Theme.space.xl
    Component.onCompleted: {
        load();
        listBoards();
    }

    Timer {
        id: boardFieldsTimer

        interval: 400
        onTriggered: settings.readDateFields()
    }

    // A setting that is on or off, its switch beside it.
    component Toggle: SettingsField {
        id: toggle

        property string key

        objectName: "plannerSetting:" + key

        control: ShellSwitch {
            checked: settings.values[toggle.key] === true
            Accessible.name: toggle.title
            onToggled: settings.set(toggle.key, checked)
        }
    }

    // A whole number of at least 1. Typed, it is set as soon as the field reads
    // one; what it cannot be is never set, and `acceptableInput` says whether the
    // field reads a count at all.
    component Count: ShellSpinBox {
        id: count

        property string key
        // What it counts, to name it to a screen reader and in a refusal.
        property string label
        readonly property bool acceptableInput: contentItem.acceptableInput

        objectName: "plannerSetting:" + key
        editable: true
        from: 1
        to: 999999999
        value: settings.values[count.key] ?? 1
        Accessible.name: label
        onValueModified: settings.set(count.key, value)
        onValueTyped: typed => settings.set(count.key, typed)
    }

    component Line: ShellTextField {
        id: line

        property string key

        objectName: "plannerSetting:" + key
        implicitWidth: 240
        text: settings.values[line.key] ?? ""
        onTextEdited: settings.set(line.key, text)
    }

    // A board field holding dates: picked from the board's date fields once they are
    // read, or None for no mapping; typed in otherwise. `label` names it to a screen reader.
    component DateField: RowLayout {
        id: dateField

        property string key
        property string label
        readonly property string value: settings.values[key] ?? ""

        ShellComboBox {
            objectName: "plannerDateField:" + dateField.key
            visible: settings.dateFields.length > 0
            outline: true
            implicitWidth: 180
            model: [qsTr("None")].concat(settings.dateFields)
            currentIndex: settings.pickedAfterNone(settings.dateFields, "", dateField.value)
            displayText: currentIndex >= 0 ? currentText : dateField.value
            Accessible.name: dateField.label
            onActivated: index => settings.set(dateField.key, index === 0 ? "" : settings.dateFields[index - 1])
        }

        Line {
            key: dateField.key
            visible: settings.dateFields.length === 0
            implicitWidth: 180
            Accessible.name: dateField.label
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
            text: qsTr("The agent")
        }

        SettingsField {
            title: qsTr("Agent and model")
            description: qsTr("Runs every action and the work on a task.")

            RowLayout {
                spacing: Theme.space.sm

                ShellComboBox {
                    objectName: "plannerSetting:provider"
                    outline: true
                    implicitWidth: 200
                    model: settings.providers.map(each => each.name)
                    currentIndex: settings.providers.findIndex(each => each.instanceId === settings.values.provider)
                    displayText: currentIndex >= 0 ? currentText : (settings.values.provider ?? "")
                    Accessible.name: qsTr("Agent")
                    onActivated: index => {
                        settings.set("provider", settings.providers[index].instanceId);
                        settings.set("model", "");
                    }
                }

                ShellComboBox {
                    readonly property var models: settings.provider?.models ?? []

                    objectName: "plannerSetting:model"
                    outline: true
                    implicitWidth: 240
                    model: [qsTr("Its default model")].concat(models.map(each => each.name || each.slug))
                    currentIndex: settings.pickedAfterNone(models, "slug", settings.values.model)
                    displayText: currentIndex >= 0 ? currentText : settings.values.model
                    Accessible.name: qsTr("Model")
                    onActivated: index => settings.set("model", index === 0 ? "" : models[index - 1].slug)
                }
            }
        }

        SettingsField {
            title: qsTr("Access for actions")
            description: qsTr("Actions read the plan and the project and report back; they rarely need more.")

            ShellChoice {
                objectName: "plannerSetting:runtimeMode"
                Layout.fillWidth: true
                options: settings.modes
                value: settings.values.runtimeMode
                onPicked: value => settings.set("runtimeMode", value)
            }
        }

        SettingsField {
            title: qsTr("Access for work on a task")
            description: qsTr("Work on a task happens in a worktree of its own.")

            ShellChoice {
                objectName: "plannerSetting:workRuntimeMode"
                Layout.fillWidth: true
                options: settings.modes
                value: settings.values.workRuntimeMode
                onPicked: value => settings.set("workRuntimeMode", value)
            }
        }

        SettingsField {
            title: qsTr("Default project")
            description: qsTr("Where actions on tasks with no project, and actions on the whole plan, run.")

            ShellComboBox {
                objectName: "plannerSetting:defaultProject"
                outline: true
                implicitWidth: 240
                model: [qsTr("None")].concat(settings.projects.map(each => each.title || each.id))
                currentIndex: settings.pickedAfterNone(settings.projects, "id", settings.values.defaultProject)
                displayText: currentIndex >= 0 ? currentText : settings.values.defaultProject
                Accessible.name: qsTr("Default project")
                onActivated: index => settings.set("defaultProject", index === 0 ? "" : settings.projects[index - 1].id)
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space.xl

            SettingsField {
                Layout.fillWidth: false
                title: qsTr("Actions at once")

                Count {
                    id: concurrencyCount

                    key: "concurrency"
                    label: qsTr("Actions at once")
                }
            }
        }

        SettingsField {
            title: qsTr("Show planner threads")
            description: qsTr("On the Planner page only, its threads stay out of the thread list.")

            ShellChoice {
                objectName: "plannerSetting:display"
                Layout.fillWidth: true
                options: [
                    { value: "page", label: qsTr("On the Planner page") },
                    { value: "threads", label: qsTr("As threads") },
                    { value: "both", label: qsTr("Both") }
                ]
                value: settings.values.display
                onPicked: value => settings.set("display", value)
            }
        }

        Toggle {
            key: "offerToAllThreads"
            title: qsTr("Let every thread read the plan")
            description: qsTr("Agents in any thread can read the plan. Only planner threads can change it.")
        }

        SettingsHeading {
            text: qsTr("Actions")
        }

        Label {
            Layout.fillWidth: true
            visible: text.length > 0
            color: settings.muted
            wrapMode: Text.Wrap
            font.pixelSize: Theme.type.meta.size
            text: qsTr("Each action's label, whether it acts on one task or the whole plan, whether its changes wait for you, and its prompt.")
        }

        Repeater {
            model: settings.actionIds

            delegate: ShellCard {
                id: card

                required property string modelData
                required property int index
                readonly property var action: settings.actions[modelData] ?? {}
                readonly property bool builtin: settings.defaultActions[modelData] !== undefined

                objectName: "plannerActionCard:" + modelData
                Layout.fillWidth: true
                implicitHeight: cardColumn.implicitHeight + 2 * Theme.space.md
                radius: Theme.radiusMd
                color: Theme.palette.color("surfaceRaised", "#1f1f23")

                ColumnLayout {
                    id: cardColumn

                    anchors.fill: parent
                    anchors.margins: Theme.space.md
                    spacing: Theme.space.sm

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.space.sm

                        ShellTextField {
                            objectName: "plannerActionLabel:" + card.modelData
                            Layout.fillWidth: true
                            text: card.action.label ?? ""
                            placeholderText: qsTr("Label")
                            Accessible.name: qsTr("Label of action %1").arg(card.index + 1)
                            onTextEdited: settings.setAction(card.modelData, "label", text)
                        }

                        ShellButton {
                            objectName: "plannerActionRemove:" + card.modelData
                            visible: !card.builtin
                            subtle: true
                            text: qsTr("Remove")
                            onClicked: settings.setAction(card.modelData, "", undefined)
                        }
                    }

                    Flow {
                        Layout.fillWidth: true
                        spacing: Theme.space.lg

                        // Work is always on one task.
                        ShellChoice {
                            objectName: "plannerActionScope:" + card.modelData
                            width: Math.min(naturalWidth, parent.width)
                            visible: card.action.kind !== "work"
                            options: [
                                { value: "item", label: qsTr("On a task") },
                                { value: "plan", label: qsTr("On the plan") }
                            ]
                            value: card.action.scope
                            Accessible.name: qsTr("What %1 acts on").arg(card.action.label || card.modelData)
                            onPicked: value => settings.setAction(card.modelData, "scope", value)
                        }

                        ShellChoice {
                            width: Math.min(naturalWidth, parent.width)
                            visible: card.action.kind !== "work"
                            options: [
                                { value: "propose", label: qsTr("Proposes changes") },
                                { value: "apply", label: qsTr("Applies changes") }
                            ]
                            value: card.action.apply
                            Accessible.name: qsTr("What %1 does with its changes").arg(card.action.label || card.modelData)
                            onPicked: value => settings.setAction(card.modelData, "apply", value)
                        }
                    }

                    ShellTextArea {
                        objectName: "plannerActionPrompt:" + card.modelData
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.max(120, implicitHeight)
                        text: card.action.prompt ?? ""
                        Accessible.name: qsTr("Prompt of %1").arg(card.action.label || card.modelData)
                        onTextChanged: if (text !== (card.action.prompt ?? ""))
                            settings.setAction(card.modelData, "prompt", text)
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.space.sm

                        Label {
                            Layout.fillWidth: true
                            visible: text.length > 0
                            color: settings.muted
                            wrapMode: Text.Wrap
                            font.pixelSize: Theme.type.meta.size
                            text: card.builtin && card.action.prompt !== settings.defaultActions[card.modelData]?.prompt ? qsTr("Changed from the plugin's prompt.") : ""
                        }

                        Item {
                            Layout.fillWidth: true
                        }

                        ShellButton {
                            objectName: "plannerActionReset:" + card.modelData
                            visible: card.builtin
                            iconName: "undo-2"
                            enabled: card.action.prompt !== settings.defaultActions[card.modelData]?.prompt
                            text: qsTr("Reset to the plugin's prompt")
                            Accessible.name: qsTr("Reset %1 to the plugin's prompt").arg(card.action.label || card.modelData)
                            onClicked: settings.resetPrompt(card.modelData)
                        }
                    }
                }
            }
        }

        Label {
            Layout.fillWidth: true
            visible: text.length > 0
            color: settings.muted
            wrapMode: Text.Wrap
            font.pixelSize: Theme.type.meta.size
            text: settings.variables
        }

        ShellButton {
            objectName: "plannerAddAction"
            text: qsTr("Add action")
            onClicked: settings.addAction()
        }

        SettingsHeading {
            text: qsTr("GitHub")
        }

        SettingsField {
            objectName: "plannerRepositories"
            title: qsTr("Repositories")
            description: qsTr("owner/name of each repository whose issues become tasks. Each needs a project on this MC.")

            Repeater {
                model: settings.watched

                delegate: RowLayout {
                    id: repository

                    required property string modelData

                    Layout.fillWidth: true
                    spacing: Theme.space.sm

                    Label {
                        Layout.fillWidth: true
                        text: repository.modelData
                        color: settings.foreground
                        elide: Text.ElideRight
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.type.body.size
                    }

                    ShellButton {
                        iconName: "x"
                        text: qsTr("Stop following")
                        Accessible.name: qsTr("Stop following %1").arg(repository.modelData)
                        onClicked: settings.unwatch(repository.modelData)
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.space.sm

                ShellTextField {
                    id: addRepository

                    Layout.fillWidth: true
                    placeholderText: qsTr("owner/name")
                    Accessible.name: qsTr("Repository to follow")
                    onAccepted: {
                        settings.watch(text);
                        text = "";
                    }
                }

                ShellButton {
                    text: qsTr("Follow")
                    enabled: addRepository.text.trim().length > 0
                    onClicked: addRepository.accepted()
                }
            }

            Flow {
                Layout.fillWidth: true
                spacing: Theme.space.sm

                Repeater {
                    model: settings.offered.filter(each => !settings.watched.some(watched => watched.toLowerCase() === each.toLowerCase()))

                    delegate: ShellButton {
                        required property string modelData

                        iconName: "plus"
                        text: modelData
                        Accessible.name: qsTr("Follow %1").arg(modelData)
                        onClicked: settings.watch(modelData)
                    }
                }
            }
        }

        SettingsField {
            title: qsTr("GitHub sync")
            description: qsTr("Both ways sends changes to a task back to its issue and board.")

            ShellChoice {
                objectName: "plannerSetting:sync"
                Layout.fillWidth: true
                options: [
                    { value: "off", label: qsTr("Off") },
                    { value: "import", label: qsTr("Import from GitHub") },
                    { value: "twoWay", label: qsTr("Both ways") }
                ]
                value: settings.values.sync
                onPicked: value => settings.set("sync", value)
            }
        }

        SettingsField {
            title: qsTr("Only issues labelled")
            description: qsTr("Empty to follow every open issue.")

            Line {
                key: "issueLabel"
                Accessible.name: qsTr("Only issues labelled")
            }
        }

        SettingsField {
            title: qsTr("GitHub Project")
            description: qsTr("A GitHub Project whose date fields are the tasks' dates, or one typed as owner/number. Needs gh's project scope.")

            RowLayout {
                spacing: Theme.space.sm

                ShellComboBox {
                    // The board's place in the list, or -1 for one typed in.
                    readonly property int chosen: {
                        if (settings.board === "")
                            return 0;
                        const index = settings.boards.findIndex(each => each.id.toLowerCase() === settings.board.trim().toLowerCase());
                        return index >= 0 ? index + 1 : -1;
                    }

                    objectName: "plannerBoard"
                    outline: true
                    implicitWidth: 260
                    model: [qsTr("None")].concat(settings.boards.map(each => each.title + " (" + each.id + ")"))
                    currentIndex: chosen
                    displayText: chosen >= 0 ? currentText : settings.board
                    Accessible.name: qsTr("GitHub Project")
                    onActivated: index => settings.set("board", index === 0 ? "" : settings.boards[index - 1].id)
                }

                ShellTextField {
                    objectName: "plannerBoardText"
                    implicitWidth: 140
                    placeholderText: qsTr("owner/number")
                    text: settings.board
                    Accessible.name: qsTr("GitHub Project as owner/number")
                    onTextEdited: settings.set("board", text.trim())
                }
            }

            Label {
                Layout.fillWidth: true
                visible: text.length > 0
                wrapMode: Text.Wrap
                font.pixelSize: Theme.type.meta.size
                objectName: "plannerBoardProblem"
                text: settings.boardProblem
                color: settings.warningColor
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.space.xl

            SettingsField {
                Layout.fillWidth: false
                title: qsTr("Start date field")

                DateField {
                    key: "startField"
                    label: qsTr("Start date field")
                }
            }

            SettingsField {
                Layout.fillWidth: false
                title: qsTr("Target date field")

                DateField {
                    key: "targetField"
                    label: qsTr("Target date field")
                }
            }
        }

        Label {
            Layout.fillWidth: true
            visible: text.length > 0
            wrapMode: Text.Wrap
            font.pixelSize: Theme.type.meta.size
            objectName: "plannerDateFieldsProblem"
            text: settings.dateFieldsProblem.length > 0 ? qsTr("The board's date fields could not be read: %1").arg(settings.dateFieldsProblem) : ""
            color: settings.warningColor
        }

        Toggle {
            key: "doneWhenMerged"
            title: qsTr("Done when its pull requests merge")
        }

        SettingsField {
            title: qsTr("Look at GitHub every (minutes)")

            Count {
                id: pollCount

                key: "pollMinutes"
                label: qsTr("Look at GitHub every (minutes)")
            }
        }

        SettingsHeading {
            text: qsTr("Slack")
        }

        Label {
            Layout.fillWidth: true
            visible: text.length > 0
            wrapMode: Text.Wrap
            font.pixelSize: Theme.type.meta.size
            objectName: "plannerSlackProblem"
            text: settings.slackConnected ? "" : qsTr("Slack is not connected on this MC. Connect it in Settings → Integrations.")
            color: settings.warningColor
        }

        SettingsField {
            title: qsTr("Post to Slack channel")
            description: qsTr("A channel the MC's Slack bot is in, as #name or its id. Empty for no Slack.")

            RowLayout {
                spacing: Theme.space.sm

                ShellComboBox {
                    // The channel's place in the list, or -1 for one typed in.
                    readonly property int chosen: {
                        const value = settings.values.slackChannel ?? "";
                        if (value === "")
                            return 0;
                        const index = settings.slackChannels.findIndex(each => "#" + each.name === value || each.id === value);
                        return index >= 0 ? index + 1 : -1;
                    }

                    objectName: "plannerSlackChannel"
                    outline: true
                    implicitWidth: 220
                    model: [qsTr("None")].concat(settings.slackChannels.map(each => "#" + each.name))
                    currentIndex: chosen
                    displayText: chosen >= 0 ? currentText : settings.values.slackChannel
                    Accessible.name: qsTr("Post to Slack channel")
                    onActivated: index => settings.set("slackChannel", index === 0 ? "" : "#" + settings.slackChannels[index - 1].name)
                }

                ShellTextField {
                    objectName: "plannerSlackChannelText"
                    implicitWidth: 180
                    placeholderText: qsTr("#channel or id")
                    text: settings.values.slackChannel ?? ""
                    Accessible.name: qsTr("Slack channel")
                    onTextEdited: settings.set("slackChannel", text.trim())
                }
            }
        }

        Toggle {
            key: "slackAnnounce"
            objectName: "plannerSlackAnnounce"
            title: qsTr("Announce proposals in Slack")
            description: qsTr("Says in the channel when an action's changes wait for you.")
        }

        SettingsField {
            title: qsTr("Slash command")
            description: qsTr("Add it to your Slack app to ask for the plan's status or run an action from Slack.")

            Line {
                key: "slackCommand"
                implicitWidth: 180
                Accessible.name: qsTr("Slash command")
            }
        }

        Label {
            objectName: "plannerRefusal"
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
                objectName: "plannerSave"
                primary: true
                text: settings.saving ? qsTr("Saving…") : qsTr("Save")
                enabled: settings.dirty && !settings.saving
                // A count typed as something it cannot be is never set, so saving would
                // keep the old one while the field shows another.
                onClicked: {
                    const wrong = [concurrencyCount, pollCount].find(count => !count.acceptableInput);
                    if (wrong)
                        settings.refusal = qsTr("%1 must be a whole number of at least 1.").arg(wrong.label);
                    else
                        settings.save(settings.changes());
                }
            }
        }
    }
}
