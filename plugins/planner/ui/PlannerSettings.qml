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
    property bool saving: false
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
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color border: Theme.palette.color("border", "#27272a")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
    readonly property color warningColor: Theme.palette.color("warning", "#f59e0b")
    readonly property var modes: [
        { value: "approval-required", label: qsTr("Ask before acting") },
        { value: "auto-accept-edits", label: qsTr("Accept edits") },
        { value: "auto", label: qsTr("Auto") },
        { value: "full-access", label: qsTr("Full access") }
    ]
    readonly property string variables: qsTr("{{today}}, {{plan}}, {{items}}, {{project}} and {{item.id}}, {{item.title}}, {{item.notes}}, {{item.status}}, {{item.start}}, {{item.due}}, {{item.progress}}, {{item.owner}}, {{item.labels}}, {{item.issue}}, {{item.pullRequests}}, {{item.subtasks}} and {{item.after}} are filled in. How to report is added after it.")

    // Reads the saved settings. Given `sent`, the values a save sent, what the user
    // changed since is kept as unsaved changes on top.
    function load(sent) {
        settings.plugin.call("settings", {}, (result, error) => {
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

    // The form stays editable while it saves; the reload keeps what was typed since.
    function save(values) {
        const sent = Object.assign({}, settings.values);
        settings.saving = true;
        settings.refusal = "";
        settings.plugin.saveSettings(values, (result, error) => {
            settings.saving = false;
            if (error)
                settings.refusal = error;
            else
                settings.load(sent);
        });
    }

    objectName: "plannerSettings"
    width: parent ? parent.width : implicitWidth
    spacing: 22
    Component.onCompleted: {
        load();
        listBoards();
    }

    Timer {
        id: boardFieldsTimer

        interval: 400
        onTriggered: settings.readDateFields()
    }

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

    // A setting that is on or off, its switch beside it.
    component Toggle: RowLayout {
        id: toggle

        property string key
        property string label
        property string hint

        objectName: "plannerSetting:" + key
        Layout.fillWidth: true
        spacing: 12

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Label {
                text: toggle.label
                color: settings.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.Medium
            }

            Hint {
                text: toggle.hint
            }
        }

        ShellSwitch {
            checked: settings.values[toggle.key] === true
            Accessible.name: toggle.label
            onToggled: settings.set(toggle.key, checked)
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

    component Count: ShellTextField {
        id: count

        property string key

        objectName: "plannerSetting:" + key
        implicitWidth: 100
        inputMethodHints: Qt.ImhDigitsOnly
        validator: IntValidator {
            bottom: 1
        }
        text: String(settings.values[count.key] ?? "")
        onTextEdited: if (acceptableInput)
            settings.set(count.key, Number(text))
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
    // read, or None for no mapping; typed in otherwise.
    component DateField: RowLayout {
        id: dateField

        property string key
        readonly property string value: settings.values[key] ?? ""

        ShellComboBox {
            objectName: "plannerDateField:" + dateField.key
            visible: settings.dateFields.length > 0
            outline: true
            implicitWidth: 180
            model: [qsTr("None")].concat(settings.dateFields)
            currentIndex: settings.pickedAfterNone(settings.dateFields, "", dateField.value)
            displayText: currentIndex >= 0 ? currentText : dateField.value
            onActivated: index => settings.set(dateField.key, index === 0 ? "" : settings.dateFields[index - 1])
        }

        Line {
            key: dateField.key
            visible: settings.dateFields.length === 0
            implicitWidth: 180
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
        Layout.fillWidth: true
        visible: settings.loaded
        spacing: 22

        Heading {
            text: qsTr("The agent")
        }

        Field {
            label: qsTr("Agent and model")
            hint: qsTr("Runs every action and the work on a task.")

            RowLayout {
                spacing: 8

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

        Field {
            label: qsTr("Access for actions")
            hint: qsTr("Actions read the plan and the project and report back; they rarely need more.")

            Choice {
                objectName: "plannerSetting:runtimeMode"
                options: settings.modes
                value: settings.values.runtimeMode
                onPicked: value => settings.set("runtimeMode", value)
            }
        }

        Field {
            label: qsTr("Access for work on a task")
            hint: qsTr("Work on a task happens in a worktree of its own.")

            Choice {
                objectName: "plannerSetting:workRuntimeMode"
                options: settings.modes
                value: settings.values.workRuntimeMode
                onPicked: value => settings.set("workRuntimeMode", value)
            }
        }

        Field {
            label: qsTr("Default project")
            hint: qsTr("Where actions on tasks with no project, and actions on the whole plan, run.")

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
            spacing: 24

            Field {
                Layout.fillWidth: false
                label: qsTr("Actions at once")

                Count {
                    key: "concurrency"
                }
            }
        }

        Field {
            label: qsTr("Show planner threads")
            hint: qsTr("On the Planner page only, its threads stay out of the thread list.")

            Choice {
                objectName: "plannerSetting:display"
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
            label: qsTr("Let every thread read the plan")
            hint: qsTr("Agents in any thread can read the plan. Only planner threads can change it.")
        }

        Heading {
            text: qsTr("Actions")
        }

        Hint {
            text: qsTr("Each action's label, whether it acts on one task or the whole plan, whether its changes wait for you, and its prompt.")
        }

        Repeater {
            model: settings.actionIds

            delegate: Rectangle {
                id: card

                required property string modelData
                readonly property var action: settings.actions[modelData] ?? {}
                readonly property bool builtin: settings.defaultActions[modelData] !== undefined

                objectName: "plannerActionCard:" + modelData
                Layout.fillWidth: true
                implicitHeight: cardColumn.implicitHeight + 24
                radius: Math.min(Theme.radius, 8)
                color: Theme.palette.color("surfaceRaised", "#1f1f23")
                border.color: settings.border

                ColumnLayout {
                    id: cardColumn

                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 10

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        ShellTextField {
                            objectName: "plannerActionLabel:" + card.modelData
                            Layout.fillWidth: true
                            text: card.action.label ?? ""
                            placeholderText: qsTr("Label")
                            Accessible.name: qsTr("Label of the action")
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
                        spacing: 16

                        // Work is always on one task.
                        Choice {
                            objectName: "plannerActionScope:" + card.modelData
                            width: implicitWidth
                            Layout.fillWidth: false
                            visible: card.action.kind !== "work"
                            options: [
                                { value: "item", label: qsTr("On a task") },
                                { value: "plan", label: qsTr("On the plan") }
                            ]
                            value: card.action.scope
                            onPicked: value => settings.setAction(card.modelData, "scope", value)
                        }

                        Choice {
                            width: implicitWidth
                            Layout.fillWidth: false
                            visible: card.action.kind !== "work"
                            options: [
                                { value: "propose", label: qsTr("Proposes changes") },
                                { value: "apply", label: qsTr("Applies changes") }
                            ]
                            value: card.action.apply
                            onPicked: value => settings.setAction(card.modelData, "apply", value)
                        }
                    }

                    Area {
                        objectName: "plannerActionPrompt:" + card.modelData
                        Layout.preferredHeight: Math.max(120, implicitHeight)
                        text: card.action.prompt ?? ""
                        Accessible.name: qsTr("Prompt of %1").arg(card.action.label ?? card.modelData)
                        onTextChanged: if (text !== (card.action.prompt ?? ""))
                            settings.setAction(card.modelData, "prompt", text)
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        Hint {
                            text: card.builtin && card.action.prompt !== settings.defaultActions[card.modelData]?.prompt ? qsTr("Changed from the plugin's prompt.") : ""
                        }

                        Item {
                            Layout.fillWidth: true
                        }

                        ShellButton {
                            objectName: "plannerActionReset:" + card.modelData
                            visible: card.builtin
                            subtle: true
                            enabled: card.action.prompt !== settings.defaultActions[card.modelData]?.prompt
                            text: qsTr("Reset to the plugin's prompt")
                            onClicked: settings.resetPrompt(card.modelData)
                        }
                    }
                }
            }
        }

        Hint {
            text: settings.variables
        }

        ShellButton {
            objectName: "plannerAddAction"
            text: qsTr("Add action")
            onClicked: settings.addAction()
        }

        Heading {
            text: qsTr("GitHub")
        }

        Field {
            objectName: "plannerRepositories"
            label: qsTr("Repositories")
            hint: qsTr("owner/name of each repository whose issues become tasks. Each needs a project on this MC.")

            Repeater {
                model: settings.watched

                delegate: RowLayout {
                    id: repository

                    required property string modelData

                    Layout.fillWidth: true
                    spacing: 8

                    Label {
                        Layout.fillWidth: true
                        text: repository.modelData
                        color: settings.foreground
                        elide: Text.ElideRight
                        font.family: Theme.fontMono
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                    }

                    ShellButton {
                        subtle: true
                        text: qsTr("Stop following")
                        onClicked: settings.unwatch(repository.modelData)
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

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
                spacing: 6

                Repeater {
                    model: settings.offered.filter(each => !settings.watched.some(watched => watched.toLowerCase() === each.toLowerCase()))

                    delegate: ShellButton {
                        required property string modelData

                        subtle: true
                        text: qsTr("+ %1").arg(modelData)
                        Accessible.name: qsTr("Follow %1").arg(modelData)
                        onClicked: settings.watch(modelData)
                    }
                }
            }
        }

        Field {
            label: qsTr("GitHub sync")
            hint: qsTr("Both ways sends changes to a task back to its issue and board.")

            Choice {
                objectName: "plannerSetting:sync"
                options: [
                    { value: "off", label: qsTr("Off") },
                    { value: "import", label: qsTr("Import from GitHub") },
                    { value: "twoWay", label: qsTr("Both ways") }
                ]
                value: settings.values.sync
                onPicked: value => settings.set("sync", value)
            }
        }

        Field {
            label: qsTr("Only issues labelled")
            hint: qsTr("Empty to follow every open issue.")

            Line {
                key: "issueLabel"
            }
        }

        Field {
            label: qsTr("GitHub Project")
            hint: qsTr("A GitHub Project whose date fields are the tasks' dates, or one typed as owner/number. Needs gh's project scope.")

            RowLayout {
                spacing: 8

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

            Hint {
                objectName: "plannerBoardProblem"
                text: settings.boardProblem
                color: settings.warningColor
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 24

            Field {
                Layout.fillWidth: false
                label: qsTr("Start date field")

                DateField {
                    key: "startField"
                }
            }

            Field {
                Layout.fillWidth: false
                label: qsTr("Target date field")

                DateField {
                    key: "targetField"
                }
            }
        }

        Hint {
            objectName: "plannerDateFieldsProblem"
            text: settings.dateFieldsProblem.length > 0 ? qsTr("The board's date fields could not be read: %1").arg(settings.dateFieldsProblem) : ""
            color: settings.warningColor
        }

        Toggle {
            key: "doneWhenMerged"
            label: qsTr("Done when its pull requests merge")
        }

        Field {
            label: qsTr("Look at GitHub every (minutes)")

            Count {
                key: "pollMinutes"
            }
        }

        Heading {
            text: qsTr("Slack")
        }

        Hint {
            objectName: "plannerSlackProblem"
            text: settings.slackConnected ? "" : qsTr("Slack is not connected on this MC. Connect it in Settings → Integrations.")
            color: settings.warningColor
        }

        Field {
            label: qsTr("Post to Slack channel")
            hint: qsTr("A channel the MC's Slack bot is in, as #name or its id. Empty for no Slack.")

            RowLayout {
                spacing: 8

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
            label: qsTr("Announce proposals in Slack")
            hint: qsTr("Says in the channel when an action's changes wait for you.")
        }

        Field {
            label: qsTr("Slash command")
            hint: qsTr("Add it to your Slack app to ask for the plan's status or run an action from Slack.")

            Line {
                key: "slackCommand"
                implicitWidth: 180
            }
        }

        Label {
            objectName: "plannerRefusal"
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
                objectName: "plannerSave"
                primary: true
                text: settings.saving ? qsTr("Saving…") : qsTr("Save")
                enabled: settings.dirty && !settings.saving
                onClicked: settings.save(settings.changes())
            }
        }
    }
}
