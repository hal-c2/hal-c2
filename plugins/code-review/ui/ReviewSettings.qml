import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// code-review's settings: the host, what is watched and when a review starts, the
// agent and its prompt, and what happens with the findings. The agents, their
// models and the repositories of the MC's projects come from the plugin's
// `settings` call; everything is saved together, and what the plugin refuses
// stays unsaved with its reason.
ColumnLayout {
    id: settings

    property var plugin
    // As the MC has them, and as the page shows them.
    property var saved: ({})
    property var values: ({})
    property var providers: []
    // Repositories of the MC's projects on the host, to suggest.
    property var offered: []
    property bool loaded: false
    property bool dirty: false
    property bool saving: false
    property string refusal: ""
    property string problem: ""
    readonly property var watched: values.repositories ?? []
    readonly property var provider: providers.find(each => each.instanceId === values.provider) ?? null
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color border: Theme.palette.color("border", "#27272a")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
    readonly property var hosts: [
        { value: "github", label: qsTr("GitHub") },
        { value: "gitlab", label: qsTr("GitLab"), disabled: true },
        { value: "forgejo", label: qsTr("Forgejo"), disabled: true },
        { value: "bitbucket", label: qsTr("Bitbucket"), disabled: true },
        { value: "azure-devops", label: qsTr("Azure DevOps"), disabled: true }
    ]
    readonly property var modes: [
        { value: "local", label: qsTr("Keep in HAL-C2") },
        { value: "draft", label: qsTr("Wait for me to publish") },
        { value: "automatic", label: qsTr("Post automatically") }
    ]

    function load() {
        settings.plugin.call("settings", {}, (result, error) => {
            if (error) {
                settings.problem = error;
                return;
            }
            settings.problem = "";
            settings.saved = result.settings ?? {};
            settings.providers = result.providers ?? [];
            settings.offered = result.repositories ?? [];
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

    // `key`'s entry for `repository` in a per-repository map, or undefined to remove it.
    function setFor(key, repository, value) {
        const next = Object.assign({}, settings.values[key] ?? {});
        if (value === undefined)
            delete next[repository];
        else
            next[repository] = value;
        settings.set(key, next);
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

    // Saves `values`; a null value returns that setting to the plugin's default.
    function save(values) {
        settings.saving = true;
        settings.refusal = "";
        settings.plugin.saveSettings(values, (result, error) => {
            settings.saving = false;
            if (error)
                settings.refusal = error;
            else
                settings.load();
        });
    }

    objectName: "codeReviewSettings"
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

    // A setting that is on or off, its switch beside it.
    component Toggle: RowLayout {
        id: toggle

        property string key
        property string label
        property string hint

        objectName: "codeReviewSetting:" + key
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

        Switch {
            checked: settings.values[toggle.key] === true
            Accessible.name: toggle.label
            onToggled: settings.set(toggle.key, checked)
        }
    }

    // One of a few values, side by side; an option can be shown and not chosen.
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
                readonly property bool open: modelData.disabled !== true

                objectName: "choice:" + modelData.value
                implicitWidth: optionText.implicitWidth + 20
                implicitHeight: 28
                radius: Math.min(Theme.radius, 8)
                color: chosen ? Theme.palette.color("accentSurface", "#27272a") : "transparent"
                border.color: chosen ? Theme.palette.color("focus", "#3b82f6") : settings.border
                opacity: open ? 1 : 0.5
                Accessible.role: Accessible.RadioButton
                Accessible.name: optionText.text
                Accessible.checkable: true
                Accessible.checked: chosen
                Accessible.onPressAction: if (open)
                    choice.picked(modelData.value)

                Text {
                    id: optionText

                    anchors.centerIn: parent
                    text: option.open ? option.modelData.label : qsTr("%1 (coming later)").arg(option.modelData.label)
                    color: settings.foreground
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: option.open
                    cursorShape: option.open ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: choice.picked(option.modelData.value)
                }
            }
        }
    }

    component Count: ShellTextField {
        id: count

        property string key

        objectName: "codeReviewSetting:" + key
        implicitWidth: 100
        inputMethodHints: Qt.ImhDigitsOnly
        validator: IntValidator {
            bottom: 0
        }
        text: String(settings.values[count.key] ?? "")
        onTextEdited: if (acceptableInput)
            settings.set(count.key, Number(text))
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
        visible: !settings.loaded
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
            text: qsTr("Source control")
        }

        Field {
            label: qsTr("Host")
            hint: qsTr("GitHub uses the gh login of this MC's machine.")

            Choice {
                objectName: "codeReviewHosts"
                options: settings.hosts
                value: settings.values.host
                onPicked: value => settings.set("host", value)
            }
        }

        Heading {
            text: qsTr("What is reviewed")
        }

        Field {
            objectName: "codeReviewRepositories"
            label: qsTr("Repositories")
            hint: qsTr("owner/name of each repository to watch. Each needs a project on this MC.")

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
                        text: qsTr("Stop watching")
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
                    Accessible.name: qsTr("Repository to watch")
                    onAccepted: {
                        settings.watch(text);
                        text = "";
                    }
                }

                ShellButton {
                    text: qsTr("Watch")
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
                        Accessible.name: qsTr("Watch %1").arg(modelData)
                        onClicked: settings.watch(modelData)
                    }
                }
            }
        }

        Field {
            label: qsTr("When a review starts")

            Choice {
                objectName: "codeReviewActivation"
                options: [
                    { value: "automatic", label: qsTr("Every new pull request") },
                    { value: "selective", label: qsTr("Only when asked") }
                ]
                value: settings.values.activation
                onPicked: value => settings.set("activation", value)
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: settings.values.activation !== "automatic"
            spacing: 16

            Toggle {
                key: "reviewRequested"
                label: qsTr("Review when you are asked to review")
                hint: qsTr("A review request to the gh user starts a review.")
            }

            Field {
                label: qsTr("Label that asks for a review")
                hint: qsTr("Leave empty to turn off.")

                ShellTextField {
                    objectName: "codeReviewSetting:label"
                    implicitWidth: 240
                    text: settings.values.label ?? ""
                    onTextEdited: settings.set("label", text)
                }
            }

            Field {
                label: qsTr("Comment that asks for a review")
                hint: qsTr("A comment starting with this starts a review. Leave empty to turn off.")

                ShellTextField {
                    objectName: "codeReviewSetting:command"
                    implicitWidth: 240
                    text: settings.values.command ?? ""
                    onTextEdited: settings.set("command", text)
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: settings.values.activation === "automatic"
            spacing: 16

            Toggle {
                key: "skipDrafts"
                label: qsTr("Skip draft pull requests")
            }

            Field {
                label: qsTr("Ignored authors")
                hint: qsTr("Logins, separated by commas.")

                ShellTextField {
                    objectName: "codeReviewSetting:ignoredAuthors"
                    Layout.fillWidth: true
                    text: (settings.values.ignoredAuthors ?? []).join(", ")
                    onTextEdited: settings.set("ignoredAuthors", text.split(",").map(each => each.trim()).filter(each => each.length > 0))
                }
            }

            Field {
                label: qsTr("Largest change reviewed automatically")
                hint: qsTr("Lines added and removed. 0 for no limit.")

                Count {
                    key: "maxChangedLines"
                }
            }
        }

        Toggle {
            key: "reviewNewPushes"
            label: qsTr("Review new pushes")
            hint: qsTr("Review a pull request again when its head changes after a review.")
        }

        Heading {
            text: qsTr("The agent")
        }

        Field {
            label: qsTr("Agent and model")

            RowLayout {
                spacing: 8

                ShellComboBox {
                    objectName: "codeReviewSetting:provider"
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

                    objectName: "codeReviewSetting:model"
                    outline: true
                    implicitWidth: 240
                    model: [qsTr("Its default model")].concat(models.map(each => each.name || each.slug))
                    currentIndex: (settings.values.model ?? "") === "" ? 0 : models.findIndex(each => each.slug === settings.values.model) + 1
                    displayText: currentIndex >= 0 ? currentText : settings.values.model
                    Accessible.name: qsTr("Model")
                    onActivated: index => settings.set("model", index === 0 ? "" : models[index - 1].slug)
                }
            }
        }

        Field {
            label: qsTr("Access")
            hint: qsTr("The agent works in its own checkout of the pull request, which runs the pull request's code if the agent runs commands.")

            Choice {
                objectName: "codeReviewSetting:runtimeMode"
                options: [
                    { value: "approval-required", label: qsTr("Ask before acting") },
                    { value: "auto-accept-edits", label: qsTr("Accept edits") },
                    { value: "auto", label: qsTr("Auto") },
                    { value: "full-access", label: qsTr("Full access") }
                ]
                value: settings.values.runtimeMode
                onPicked: value => settings.set("runtimeMode", value)
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 24

            Field {
                Layout.fillWidth: false
                label: qsTr("Reviews at once")

                Count {
                    key: "concurrency"
                }
            }

            Field {
                Layout.fillWidth: false
                label: qsTr("Look for pull requests every (minutes)")

                Count {
                    key: "pollMinutes"
                }
            }
        }

        Field {
            label: qsTr("Review prompt")
            hint: qsTr("{{pr.number}}, {{pr.title}}, {{pr.author}}, {{pr.base}}, {{pr.head}}, {{pr.headSha}}, {{pr.mergeBase}}, {{pr.url}} and {{repository}} are filled in. How to report the findings is added after it.")

            Area {
                objectName: "codeReviewSetting:prompt"
                Layout.preferredHeight: Math.max(160, implicitHeight)
                text: settings.values.prompt ?? ""
                Accessible.name: qsTr("Review prompt")
                onTextChanged: if (activeFocus)
                    settings.set("prompt", text)
            }

            ShellButton {
                objectName: "codeReviewResetPrompt"
                subtle: true
                enabled: !settings.saving
                text: qsTr("Reset to the plugin's prompt")
                onClicked: settings.save(Object.assign({}, settings.values, { prompt: null }))
            }
        }

        Toggle {
            key: "readReviewMd"
            label: qsTr("Follow REVIEW.md")
            hint: qsTr("Add the REVIEW.md at the pull request's head to the prompt.")
        }

        Repeater {
            model: settings.watched

            delegate: Field {
                id: instructions

                required property string modelData

                label: qsTr("Instructions for %1").arg(modelData)
                hint: qsTr("Added to the prompt for this repository.")

                Area {
                    Layout.preferredHeight: Math.max(64, implicitHeight)
                    text: (settings.values.instructions ?? {})[instructions.modelData] ?? ""
                    Accessible.name: instructions.label
                    onTextChanged: if (activeFocus)
                        settings.setFor("instructions", instructions.modelData, text.trim().length > 0 ? text : undefined)
                }
            }
        }

        Heading {
            text: qsTr("The findings")
        }

        Field {
            label: qsTr("Show reviews")
            hint: qsTr("On the Reviews page only, review threads stay out of the thread list.")

            Choice {
                objectName: "codeReviewSetting:display"
                options: [
                    { value: "page", label: qsTr("On the Reviews page") },
                    { value: "threads", label: qsTr("As threads") },
                    { value: "both", label: qsTr("Both") }
                ]
                value: settings.values.display
                onPicked: value => settings.set("display", value)
            }
        }

        Field {
            label: qsTr("Publishing")

            Choice {
                objectName: "codeReviewSetting:publishing"
                options: settings.modes
                value: settings.values.publishing
                onPicked: value => settings.set("publishing", value)
            }
        }

        Repeater {
            model: settings.watched

            delegate: Field {
                id: publishing

                required property string modelData

                label: qsTr("Publishing for %1").arg(modelData)

                Choice {
                    options: [{ value: "", label: qsTr("As above") }].concat(settings.modes)
                    value: (settings.values.publishingByRepository ?? {})[publishing.modelData] ?? ""
                    onPicked: value => settings.setFor("publishingByRepository", publishing.modelData, value === "" ? undefined : value)
                }
            }
        }

        Toggle {
            key: "verdictAsComment"
            label: qsTr("Post verdicts as comments")
            hint: qsTr("Post reviews as comments rather than approvals or change requests.")
        }

        Label {
            objectName: "codeReviewRefusal"
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
                objectName: "codeReviewSave"
                primary: true
                text: settings.saving ? qsTr("Saving…") : qsTr("Save")
                enabled: settings.dirty && !settings.saving
                onClicked: settings.save(settings.values)
            }
        }
    }
}
