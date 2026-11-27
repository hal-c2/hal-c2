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
    // The model reviews will run on: the picked one, else the agent's default.
    readonly property var modelEntry: (provider?.models ?? []).find(each => each.slug === values.model) ?? (provider?.models ?? []).find(each => each.isDefault) ?? (provider?.models ?? [])[0] ?? null
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("inkTertiary", "#a1a1aa")
    readonly property color errorColor: Theme.palette.color("errorForeground", "#ef4444")
    // Shown and not yet chosen: the hosts it will review on later.
    readonly property var hosts: [
        { value: "github", label: qsTr("GitHub") },
        { value: "gitlab", label: qsTr("%1 (coming later)").arg(qsTr("GitLab")), disabled: true },
        { value: "forgejo", label: qsTr("Forgejo") },
        { value: "bitbucket", label: qsTr("%1 (coming later)").arg(qsTr("Bitbucket")), disabled: true },
        { value: "azure-devops", label: qsTr("%1 (coming later)").arg(qsTr("Azure DevOps")), disabled: true }
    ]
    readonly property var modes: [
        { value: "local", label: qsTr("Keep in HAL-C2") },
        { value: "draft", label: qsTr("Wait for me to publish") },
        { value: "automatic", label: qsTr("Post automatically") }
    ]

    // Reads the saved settings; `edits`, unsaved changes to keep, are made again on top.
    function load(edits) {
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
            for (const key in edits ?? {})
                settings.set(key, edits[key]);
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
    // `edits` stay unsaved changes once it is saved.
    function save(values, edits) {
        settings.saving = true;
        settings.refusal = "";
        settings.plugin.saveSettings(values, (result, error) => {
            settings.saving = false;
            if (error)
                settings.refusal = error;
            else
                settings.load(edits);
        });
    }

    // Returns the prompt to the plugin's own and saves only that; the user's other
    // changes stay unsaved.
    function resetPrompt() {
        const edits = {};
        for (const key in settings.values) {
            if (key !== "prompt" && JSON.stringify(settings.values[key]) !== JSON.stringify(settings.saved[key]))
                edits[key] = settings.values[key];
        }
        settings.save({ prompt: null }, edits);
    }

    objectName: "codeReviewSettings"
    width: parent ? parent.width : implicitWidth
    spacing: Theme.space.xl
    Component.onCompleted: load()

    // A setting that is on or off, its switch beside it.
    component Toggle: SettingsField {
        id: toggle

        property string key

        objectName: "codeReviewSetting:" + key
        control: ShellSwitch {
            checked: settings.values[toggle.key] === true
            Accessible.name: toggle.title
            onToggled: settings.set(toggle.key, checked)
        }
    }

    // A whole number, 0 or more.
    component Count: ShellSpinBox {
        id: count

        property string key

        objectName: "codeReviewSetting:" + key
        editable: true
        from: 0
        to: 999999999
        value: settings.values[count.key] ?? 0
        onValueModified: settings.set(count.key, value)
        onValueTyped: typed => settings.set(count.key, typed)
    }

    // Logins separated by commas. The text stays as typed while it is edited, with
    // what it names set as it changes, and is shown from the setting again once
    // editing ends, or when the setting changes to other logins (a reset, a load).
    component Logins: ShellTextField {
        id: logins

        property string key
        readonly property var list: settings.values[logins.key] ?? []

        function parse(text) {
            return text.split(",").map(each => each.trim()).filter(each => each.length > 0);
        }

        function show() {
            logins.text = logins.list.join(", ");
        }

        objectName: "codeReviewSetting:" + key
        Layout.fillWidth: true
        Component.onCompleted: show()
        onListChanged: if (JSON.stringify(logins.parse(logins.text)) !== JSON.stringify(logins.list))
            logins.show()
        onTextEdited: settings.set(logins.key, logins.parse(logins.text))
        onEditingFinished: show()
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
            text: qsTr("Source control")
        }

        SettingsField {
            title: qsTr("Host")
            description: qsTr("GitHub uses the gh login of this MC's machine; Forgejo, its fj or tea login.")

            ShellChoice {
                objectName: "codeReviewHosts"
                Layout.fillWidth: true
                options: settings.hosts
                value: settings.values.host
                onPicked: value => settings.set("host", value)
            }
        }

        SettingsHeading {
            text: qsTr("What is reviewed")
        }

        SettingsField {
            objectName: "codeReviewRepositories"
            title: qsTr("Repositories")
            description: qsTr("owner/name of each repository to watch. Each needs a project on this MC.")

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
                        text: qsTr("Stop watching")
                        Accessible.name: qsTr("Stop watching %1").arg(repository.modelData)
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
                spacing: Theme.space.sm

                Repeater {
                    model: settings.offered.filter(each => !settings.watched.some(watched => watched.toLowerCase() === each.toLowerCase()))

                    delegate: ShellButton {
                        required property string modelData

                        iconName: "plus"
                        text: modelData
                        Accessible.name: qsTr("Watch %1").arg(modelData)
                        onClicked: settings.watch(modelData)
                    }
                }
            }
        }

        SettingsField {
            title: qsTr("When a review starts")

            ShellChoice {
                objectName: "codeReviewActivation"
                Layout.fillWidth: true
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
            spacing: Theme.space.lg

            Toggle {
                key: "reviewRequested"
                title: qsTr("Review when you are asked to review")
                description: qsTr("A review request to the signed-in account starts a review.")
            }

            SettingsField {
                title: qsTr("Label that asks for a review")
                description: qsTr("Leave empty to turn off.")

                ShellTextField {
                    objectName: "codeReviewSetting:label"
                    Accessible.name: qsTr("Label that asks for a review")
                    Accessible.description: qsTr("Leave empty to turn off.")
                    implicitWidth: 240
                    text: settings.values.label ?? ""
                    onTextEdited: settings.set("label", text)
                }
            }

            SettingsField {
                title: qsTr("Comment that asks for a review")
                description: qsTr("A comment starting with this starts a review. Leave empty to turn off.")

                ShellTextField {
                    objectName: "codeReviewSetting:command"
                    Accessible.name: qsTr("Comment that asks for a review")
                    Accessible.description: qsTr("A comment starting with this starts a review. Leave empty to turn off.")
                    implicitWidth: 240
                    text: settings.values.command ?? ""
                    onTextEdited: settings.set("command", text)
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: settings.values.activation === "automatic"
            spacing: Theme.space.lg

            Toggle {
                key: "skipDrafts"
                title: qsTr("Skip draft pull requests")
            }

            SettingsField {
                title: qsTr("Ignored authors")
                description: qsTr("Logins, separated by commas.")

                Logins {
                    key: "ignoredAuthors"
                    Accessible.name: qsTr("Ignored authors")
                    Accessible.description: qsTr("Logins, separated by commas.")
                }
            }

            SettingsField {
                title: qsTr("Largest change reviewed automatically")
                description: qsTr("Lines added and removed. 0 for no limit.")

                Count {
                    key: "maxChangedLines"
                    Accessible.name: qsTr("Largest change reviewed automatically")
                    Accessible.description: qsTr("Lines added and removed. 0 for no limit.")
                }
            }
        }

        Toggle {
            key: "reviewNewPushes"
            title: qsTr("Review new pushes")
            description: qsTr("Review a pull request again when its head changes after a review.")
        }

        Toggle {
            key: "reviewRebases"
            title: qsTr("Review rebases")
            description: qsTr("Review a new push again even when it only rebases the change already reviewed.")
        }

        SettingsField {
            title: qsTr("Trusted logins")
            description: qsTr("Logins, separated by commas. Besides the repository's members and collaborators, these may have their pull requests reviewed and ask for reviews. Approve anyone else's pull request on the Reviews page.")

            Logins {
                key: "trustedLogins"
                Accessible.name: qsTr("Trusted logins")
                Accessible.description: qsTr("Logins, separated by commas, whose pull requests are reviewed and who may ask for reviews.")
            }
        }

        // Side by side where they fit, one under the other on a narrow screen.
        Flow {
            Layout.fillWidth: true
            spacing: Theme.space.xl

            SettingsField {
                title: qsTr("Reviews per author a day")
                description: qsTr("Across your machines. 0 for no limit.")

                Count {
                    key: "reviewsPerAuthorPerDay"
                    Accessible.name: qsTr("Reviews per author a day")
                    Accessible.description: qsTr("Across your machines. 0 for no limit.")
                }
            }

            SettingsField {
                title: qsTr("Reviews per repository a day")
                description: qsTr("Reviews you start yourself are never held back.")

                Count {
                    key: "reviewsPerRepositoryPerDay"
                    Accessible.name: qsTr("Reviews per repository a day")
                    Accessible.description: qsTr("Reviews you start yourself are never held back.")
                }
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
                        settings.set("modelOptions", ({}));
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
                    onActivated: index => {
                        settings.set("model", index === 0 ? "" : models[index - 1].slug);
                        settings.set("modelOptions", ({}));
                    }
                }
            }
        }

        // What the chosen model offers besides itself: its reasoning effort first of all.
        Repeater {
            model: settings.modelEntry?.options ?? []

            delegate: SettingsField {
                id: option

                required property var modelData

                objectName: "codeReviewSetting:modelOption:" + modelData.id
                title: modelData.label ?? modelData.id

                control: ShellSwitch {
                    visible: option.modelData.type === "boolean"
                    checked: (settings.values.modelOptions ?? {})[option.modelData.id] === true
                    Accessible.name: option.title
                    onToggled: settings.setFor("modelOptions", option.modelData.id, checked)
                }

                ShellChoice {
                    Layout.fillWidth: true
                    visible: option.modelData.type !== "boolean"
                    options: [{ value: "", label: qsTr("Its default") }].concat((option.modelData.options ?? []).map(each => ({ value: each.id, label: each.label ?? each.id })))
                    value: (settings.values.modelOptions ?? {})[option.modelData.id] ?? ""
                    onPicked: value => settings.setFor("modelOptions", option.modelData.id, value === "" ? undefined : value)
                }
            }
        }

        SettingsField {
            title: qsTr("Access")
            description: qsTr("The agent works in its own checkout of the pull request, which runs the pull request's code if the agent runs commands.")

            ShellChoice {
                objectName: "codeReviewSetting:runtimeMode"
                Layout.fillWidth: true
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

        // Reviews run in a sandbox, and fail rather than run here when they cannot:
        // an agent that cannot run in one fails every review it would sandbox.
        Label {
            objectName: "codeReviewSandboxAgent"
            Layout.fillWidth: true
            visible: settings.provider !== null && settings.provider.sandboxable === false
            text: settings.values.reviewTrustedOnThisMachine === true
                ? qsTr("%1 cannot run in a sandbox yet, so reviews of pull requests HAL-C2 does not trust fail. Pick Claude or Codex to review them.").arg(settings.provider?.name ?? "")
                : qsTr("Every review runs in a sandbox, which %1 cannot run in yet, so its reviews fail. Pick Claude or Codex.").arg(settings.provider?.name ?? "")
            color: settings.errorColor
            wrapMode: Text.Wrap
            font.pixelSize: Theme.type.body.size
        }

        // An agent that can run in a sandbox may still have no way to its model there,
        // a sign-in with no API key above all; the MC says why, and what to pick instead.
        Label {
            objectName: "codeReviewSandboxRoute"
            Layout.fillWidth: true
            visible: settings.provider !== null && settings.provider.sandboxable !== false && !!settings.provider.sandboxRefusal
            text: settings.values.reviewTrustedOnThisMachine === true
                ? qsTr("Reviews of pull requests HAL-C2 does not trust run in a sandbox, where %1 fails: %2").arg(settings.provider?.name ?? "").arg(settings.provider?.sandboxRefusal ?? "")
                : qsTr("Every review runs in a sandbox, where %1 fails: %2").arg(settings.provider?.name ?? "").arg(settings.provider?.sandboxRefusal ?? "")
            color: settings.errorColor
            wrapMode: Text.Wrap
            font.pixelSize: Theme.type.body.size
        }

        Toggle {
            key: "reviewTrustedOnThisMachine"
            title: qsTr("Review trusted pull requests on this machine")
            description: qsTr("Off, every review runs in an OpenShell sandbox, with Claude or Codex and an API key; Settings → Review sandboxes shows whether this MC can make one. On, reviews of pull requests HAL-C2 trusts run here, with their tool to report and none of HAL-C2's others: the pull request's code and text then reach this machine, its files and its credentials. A pull request opened by someone who is not a member, collaborator or trusted login, or whose commits come from someone else's fork, is reviewed in a sandbox either way.")
        }

        // Side by side where they fit, one under the other on a narrow screen.
        Flow {
            Layout.fillWidth: true
            spacing: Theme.space.xl

            SettingsField {
                title: qsTr("Sandboxed review time limit (minutes)")

                Count {
                    key: "sandboxMinutes"
                    Accessible.name: qsTr("Sandboxed review time limit (minutes)")
                }
            }

            SettingsField {
                title: qsTr("Sandboxed review token budget")
                description: qsTr("0 for no limit.")

                Count {
                    key: "sandboxTokens"
                    Accessible.name: qsTr("Sandboxed review token budget")
                    Accessible.description: qsTr("0 for no limit.")
                }
            }
        }

        // Side by side where they fit, one under the other on a narrow screen.
        Flow {
            Layout.fillWidth: true
            spacing: Theme.space.xl

            SettingsField {
                title: qsTr("Reviews at once")

                Count {
                    key: "concurrency"
                    Accessible.name: qsTr("Reviews at once")
                }
            }

            SettingsField {
                title: qsTr("Look for pull requests every (minutes)")

                Count {
                    key: "pollMinutes"
                    Accessible.name: qsTr("Look for pull requests every (minutes)")
                }
            }
        }

        SettingsField {
            title: qsTr("Review prompt")
            description: qsTr("{{pr.number}}, {{pr.title}}, {{pr.author}}, {{pr.base}}, {{pr.head}}, {{pr.headSha}}, {{pr.mergeBase}}, {{pr.url}}, {{pr.body}} and {{repository}} are filled in. The description, failing checks, comments already on the pull request and your previous review of it are added after it, then how to report the findings.")

            ShellTextArea {
                objectName: "codeReviewSetting:prompt"
                Layout.fillWidth: true
                Layout.preferredHeight: Math.max(160, implicitHeight)
                text: settings.values.prompt ?? ""
                Accessible.name: qsTr("Review prompt")
                onTextChanged: if (activeFocus)
                    settings.set("prompt", text)
            }

            ShellButton {
                objectName: "codeReviewResetPrompt"
                iconName: "undo-2"
                enabled: !settings.saving
                text: qsTr("Reset to the plugin's prompt")
                onClicked: settings.resetPrompt()
            }
        }

        Toggle {
            key: "readReviewMd"
            title: qsTr("Follow REVIEW.md")
            description: qsTr("Add the REVIEW.md on the pull request's base branch to the prompt.")
        }

        Repeater {
            model: settings.watched

            delegate: SettingsField {
                id: instructions

                required property string modelData

                title: qsTr("Instructions for %1").arg(modelData)
                description: qsTr("Added to the prompt for this repository.")

                ShellTextArea {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.max(64, implicitHeight)
                    text: (settings.values.instructions ?? {})[instructions.modelData] ?? ""
                    Accessible.name: instructions.title
                    onTextChanged: if (activeFocus)
                        settings.setFor("instructions", instructions.modelData, text.trim().length > 0 ? text : undefined)
                }
            }
        }

        SettingsHeading {
            text: qsTr("The findings")
        }

        SettingsField {
            title: qsTr("Show reviews")
            description: qsTr("On the Reviews page only, review threads stay out of the thread list.")

            ShellChoice {
                objectName: "codeReviewSetting:display"
                Layout.fillWidth: true
                options: [
                    { value: "page", label: qsTr("On the Reviews page") },
                    { value: "threads", label: qsTr("As threads") },
                    { value: "both", label: qsTr("Both") }
                ]
                value: settings.values.display
                onPicked: value => settings.set("display", value)
            }
        }

        SettingsField {
            title: qsTr("Publishing")

            ShellChoice {
                objectName: "codeReviewSetting:publishing"
                Layout.fillWidth: true
                options: settings.modes
                value: settings.values.publishing
                onPicked: value => settings.set("publishing", value)
            }
        }

        Repeater {
            model: settings.watched

            delegate: SettingsField {
                id: publishing

                required property string modelData

                title: qsTr("Publishing for %1").arg(modelData)

                ShellChoice {
                    Layout.fillWidth: true
                    options: [{ value: "", label: qsTr("As above") }].concat(settings.modes)
                    value: (settings.values.publishingByRepository ?? {})[publishing.modelData] ?? ""
                    onPicked: value => settings.setFor("publishingByRepository", publishing.modelData, value === "" ? undefined : value)
                }
            }
        }

        SettingsField {
            title: qsTr("Review heading")
            description: qsTr("The first line of every posted review. Leave empty for none.")

            ShellTextField {
                objectName: "codeReviewSetting:heading"
                Accessible.name: qsTr("Review heading")
                Accessible.description: qsTr("The first line of every posted review. Leave empty for none.")
                implicitWidth: 240
                text: settings.values.heading ?? ""
                onTextEdited: settings.set("heading", text)
            }
        }

        Toggle {
            key: "verdictAsComment"
            title: qsTr("Post verdicts as comments")
            description: qsTr("Post reviews as comments rather than approvals or change requests.")
        }

        Label {
            objectName: "codeReviewRefusal"
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
                objectName: "codeReviewDiscard"
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
