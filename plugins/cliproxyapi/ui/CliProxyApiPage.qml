pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// CLIProxyAPI's page, for one MC at a time: the proxy (running, failing, refusing
// its key, an update out) with a Retry, the provider instances the plugin keeps
// with an Add back for one the user deleted, the accounts signed in to it (sign in
// to Claude or Codex, switch one off, remove it), what each account and model used,
// the upstream API keys (masked, added and removed here) and the proxy's log.
//
// Signing in works from any device: the page shows the address to open, and the
// browser ends on a localhost page that only loads on the MC's machine. The user
// pastes that page's address back here, and the MC hands it to the proxy.
//
// Follows the plugin's `status`, `accounts`, `usage`, `keys` and `logs` topics,
// asked once by `status` and then pushed as they change; it never polls.
Item {
    id: page

    property var plugin
    property string environment: ""
    property var watches: []
    property var status: null
    property var accounts: []
    property var signIn: null
    property var usage: []
    property var keys: []
    property var logs: []
    property string refusal: ""

    readonly property string phase: status?.state ?? ""
    readonly property bool running: phase === "running" || phase === "connected"
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color border: Theme.palette.color("border", "#27272a")
    readonly property color warningColor: Theme.palette.color("warning", "#f59e0b")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
    readonly property bool narrow: width < 560

    function follow() {
        if (!page.plugin.environments.includes(page.environment))
            page.environment = page.plugin.environments[0] ?? "";
    }

    function load() {
        for (const watch of page.watches)
            page.plugin.unwatch(watch);
        page.watches = [];
        page.status = null;
        page.accounts = [];
        page.signIn = null;
        page.usage = [];
        page.keys = [];
        page.logs = [];
        page.refusal = "";
        if (page.environment.length === 0)
            return;
        const environment = page.environment;
        page.plugin.call("status", {}, result => {
            if (result && page.environment === environment && page.status === null)
                page.take(result);
        }, environment);
        page.watches = [page.plugin.watch("status", value => page.status = value, environment), page.plugin.watch("accounts", value => {
                page.accounts = value?.accounts ?? [];
                page.signIn = value?.signIn ?? null;
            }, environment), page.plugin.watch("usage", value => page.usage = value?.rows ?? [], environment), page.plugin.watch("keys", value => page.keys = value?.keys ?? [], environment), page.plugin.watch("logs", value => page.logs = value?.lines ?? [], environment)];
    }

    // The answer of `status`, `refresh`, `retry` and `addInstance`: everything the page shows.
    function take(view) {
        if (!view)
            return;
        page.status = view.status ?? null;
        page.accounts = view.accounts ?? [];
        page.signIn = view.signIn ?? null;
        page.usage = view.usage ?? [];
        page.keys = view.keys ?? [];
        page.logs = view.logs ?? [];
    }

    function start(method, input, done) {
        page.refusal = "";
        page.plugin.call(method, input, (result, error) => {
            if (error)
                page.refusal = error;
            else if (done)
                done(result);
        }, page.environment);
    }

    function stateLine() {
        const version = status?.version ?? "";
        switch (page.phase) {
        case "running":
            return qsTr("Running CLIProxyAPI %1 at %2").arg(version).arg(status.address);
        case "starting":
            return qsTr("Starting CLIProxyAPI %1…").arg(version);
        case "restarting":
            return qsTr("Restarting CLIProxyAPI %1").arg(version);
        case "downloading":
            return qsTr("Downloading CLIProxyAPI %1…").arg(version);
        case "connected":
            return qsTr("Connected to CLIProxyAPI at %1").arg(status.address);
        case "connecting":
            return qsTr("Connecting to CLIProxyAPI at %1…").arg(status.address);
        case "unreachable":
            return qsTr("CLIProxyAPI at %1 does not answer").arg(status.address);
        case "blocked":
            return qsTr("CLIProxyAPI refused the management key");
        case "failed":
            return qsTr("CLIProxyAPI did not start");
        case "stopped":
            return qsTr("CLIProxyAPI is stopped");
        default:
            return qsTr("Waiting for the CLIProxyAPI plugin…");
        }
    }

    function providerLabel(provider) {
        return ({
                "claude": qsTr("Claude"),
                "codex": qsTr("Codex"),
                "gemini": qsTr("Gemini")
            })[provider] ?? provider;
    }

    function tokens(count) {
        return count >= 1000000 ? qsTr("%1M").arg((count / 1000000).toFixed(1)) : count >= 1000 ? qsTr("%1k").arg((count / 1000).toFixed(1)) : String(count);
    }

    function environmentLabel(environment) {
        const known = (Shell.state.mcPlugins?.environments ?? []).find(each => each.id === environment);
        return known?.label ?? environment;
    }

    objectName: "cliproxyapiPage"
    implicitWidth: 900
    implicitHeight: 600
    Component.onCompleted: follow()
    onEnvironmentChanged: load()

    Connections {
        target: page.plugin

        function onEnvironmentsChanged() {
            page.follow();
        }
    }

    component Heading: Text {
        Layout.fillWidth: true
        Layout.topMargin: 8
        color: page.foreground
        font.pixelSize: Theme.type.body.size
        font.weight: Font.Medium
        elide: Text.ElideRight
    }

    component Note: Text {
        Layout.fillWidth: true
        visible: text.length > 0
        color: page.muted
        wrapMode: Text.Wrap
        font.pixelSize: Theme.type.meta.size
    }

    component Rule: Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 1
        color: page.border
    }

    Flickable {
        anchors.fill: parent
        clip: true
        contentHeight: content.implicitHeight + 32
        boundsBehavior: Flickable.StopAtBounds

        ScrollBar.vertical: ScrollBar {}

        ColumnLayout {
            id: content

            x: 16
            y: 16
            width: page.width - 32
            spacing: 8

            // --- the proxy ---
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    objectName: "cliproxyapiState"
                    Layout.fillWidth: true
                    text: page.stateLine()
                    color: page.phase === "blocked" || page.phase === "failed" || page.phase === "unreachable" ? page.errorColor : page.foreground
                    wrapMode: Text.Wrap
                    font.pixelSize: Theme.type.body.size
                    font.weight: Font.Medium
                }

                ShellComboBox {
                    visible: page.plugin.environments.length > 1
                    outline: true
                    implicitWidth: 160
                    model: page.plugin.environments.map(environment => page.environmentLabel(environment))
                    currentIndex: page.plugin.environments.indexOf(page.environment)
                    Accessible.name: qsTr("Machine")
                    onActivated: index => page.environment = page.plugin.environments[index]
                }

                ShellButton {
                    objectName: "cliproxyapiRetry"
                    visible: page.phase === "blocked" || page.phase === "failed" || page.phase === "unreachable"
                    primary: true
                    text: qsTr("Retry")
                    onClicked: page.start("retry", {}, result => page.take(result))
                }

                ShellButton {
                    objectName: "cliproxyapiRefresh"
                    subtle: true
                    visible: page.running
                    text: qsTr("Refresh")
                    onClicked: page.start("refresh", {}, result => page.take(result))
                }
            }

            Note {
                objectName: "cliproxyapiMessage"
                text: page.status?.message ?? ""
                color: page.phase === "restarting" || page.phase === "starting" ? page.muted : page.errorColor
            }

            Note {
                objectName: "cliproxyapiError"
                text: page.status?.error ?? ""
                color: page.warningColor
            }

            Note {
                objectName: "cliproxyapiProblem"
                text: page.refusal
                color: page.warningColor
            }

            Note {
                objectName: "cliproxyapiUpdate"
                text: page.status?.latest ? qsTr("CLIProxyAPI %1 is out. This plugin runs %2, the version it was tested with, until the plugin is updated; set its binary to run another.").arg(page.status.latest).arg(page.status.version) : ""
                color: page.warningColor
            }

            Note {
                objectName: "cliproxyapiBinary"
                text: page.status?.binary ? qsTr("%1 (%2)").arg(page.status.binary).arg(({
                        "setting": qsTr("from the plugin's settings"),
                        "path": qsTr("from PATH"),
                        "download": qsTr("downloaded")
                    })[page.status.source] ?? page.status.source) : ""
            }

            Repeater {
                model: page.status?.instances ?? []

                delegate: RowLayout {
                    id: instance

                    required property var modelData

                    objectName: "cliproxyapiInstance:" + modelData.name
                    Layout.fillWidth: true
                    spacing: 8

                    Text {
                        objectName: "cliproxyapiInstanceText:" + instance.modelData.name
                        Layout.fillWidth: true
                        text: instance.modelData.state === "dismissed" ? qsTr("%1 · deleted from Settings → Providers").arg(instance.modelData.label) : instance.modelData.state === "taken" ? qsTr("%1 · not added: %2").arg(instance.modelData.label).arg(instance.modelData.message ?? "") : qsTr("%1 · in Settings → Providers").arg(instance.modelData.label)
                        color: instance.modelData.state === "added" ? page.foreground : page.muted
                        wrapMode: Text.Wrap
                        font.pixelSize: Theme.type.meta.size
                    }

                    ShellButton {
                        objectName: "cliproxyapiAddBack:" + instance.modelData.name
                        visible: instance.modelData.state === "dismissed"
                        subtle: true
                        text: qsTr("Add back")
                        onClicked: page.start("addInstance", {
                            name: instance.modelData.name
                        }, result => page.take(result))
                    }
                }
            }

            // --- accounts ---
            Rule {}

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Heading {
                    text: qsTr("Accounts")
                }

                ShellButton {
                    objectName: "cliproxyapiSignIn:claude"
                    enabled: page.running && page.signIn?.status !== "wait"
                    text: qsTr("Sign in to Claude")
                    onClicked: page.start("signIn", {
                        provider: "claude"
                    })
                }

                ShellButton {
                    objectName: "cliproxyapiSignIn:codex"
                    enabled: page.running && page.signIn?.status !== "wait"
                    text: qsTr("Sign in to Codex")
                    onClicked: page.start("signIn", {
                        provider: "codex"
                    })
                }
            }

            ColumnLayout {
                objectName: "cliproxyapiSignInPanel"
                Layout.fillWidth: true
                visible: page.signIn !== null
                spacing: 6

                Note {
                    objectName: "cliproxyapiSignInHelp"
                    color: page.foreground
                    text: page.signIn?.status === "wait" ? qsTr("Open this address in a browser on any device and sign in to %1. The browser then ends on a localhost page that does not load: copy that page's whole address and paste it below.").arg(page.providerLabel(page.signIn.provider)) : ""
                }

                RowLayout {
                    Layout.fillWidth: true
                    visible: page.signIn?.status === "wait"
                    spacing: 8

                    ShellTextField {
                        objectName: "cliproxyapiSignInUrl"
                        Layout.fillWidth: true
                        readOnly: true
                        selectByMouse: true
                        text: page.signIn?.url ?? ""
                        Accessible.name: qsTr("Sign-in address")
                    }

                    ShellButton {
                        objectName: "cliproxyapiOpenSignIn"
                        text: qsTr("Open")
                        onClicked: Qt.openUrlExternally(page.signIn.url)
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    visible: page.signIn?.status === "wait"
                    spacing: 8

                    ShellTextField {
                        id: address

                        objectName: "cliproxyapiSignInAddress"
                        Layout.fillWidth: true
                        placeholderText: qsTr("http://localhost:…/callback?code=…")
                        Accessible.name: qsTr("The address the browser ended on")
                        onAccepted: finish.clicked()
                    }

                    ShellButton {
                        id: finish

                        objectName: "cliproxyapiFinishSignIn"
                        primary: true
                        enabled: address.text.trim().length > 0
                        text: qsTr("Finish")
                        onClicked: page.start("finishSignIn", {
                            address: address.text
                        }, () => address.clear())
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Note {
                        objectName: "cliproxyapiSignInError"
                        text: page.signIn?.status === "error" ? qsTr("The sign-in failed: %1").arg(page.signIn.error) : ""
                        color: page.errorColor
                    }

                    ShellButton {
                        objectName: "cliproxyapiCancelSignIn"
                        subtle: true
                        text: page.signIn?.status === "wait" ? qsTr("Cancel") : qsTr("Dismiss")
                        onClicked: page.start("cancelSignIn", {})
                    }
                }
            }

            Note {
                visible: page.accounts.length === 0 && page.signIn === null
                text: page.running ? qsTr("No accounts yet. Sign in to Claude or Codex, or add an API key below.") : ""
            }

            Repeater {
                model: page.accounts

                delegate: RowLayout {
                    id: account

                    required property var modelData

                    objectName: "cliproxyapiAccount:" + modelData.name
                    Layout.fillWidth: true
                    spacing: 8

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2

                        Text {
                            Layout.fillWidth: true
                            text: qsTr("%1 · %2").arg(page.providerLabel(account.modelData.provider)).arg(account.modelData.email || account.modelData.name)
                            color: account.modelData.disabled ? page.muted : page.foreground
                            elide: Text.ElideRight
                            font.pixelSize: Theme.type.body.size
                        }

                        Note {
                            text: [account.modelData.disabled ? qsTr("switched off") : account.modelData.unavailable ? qsTr("resting after a limit") : (account.modelData.status ?? ""), account.modelData.message ?? ""].filter(part => part.length > 0).join(" · ")
                        }
                    }

                    ShellButton {
                        objectName: "cliproxyapiToggle:" + account.modelData.name
                        subtle: true
                        text: account.modelData.disabled ? qsTr("Switch on") : qsTr("Switch off")
                        onClicked: page.start("toggleAccount", {
                            name: account.modelData.name,
                            disabled: !account.modelData.disabled
                        })
                    }

                    ShellButton {
                        objectName: "cliproxyapiRemove:" + account.modelData.name
                        subtle: true
                        destructive: true
                        text: qsTr("Remove")
                        onClicked: page.start("removeAccount", {
                            name: account.modelData.name
                        })
                    }
                }
            }

            // --- usage ---
            Rule {}

            Heading {
                text: qsTr("Usage, last 7 days")
            }

            Note {
                visible: page.usage.length === 0
                text: qsTr("Nothing used yet.")
            }

            Repeater {
                model: page.usage

                delegate: Text {
                    id: row

                    required property var modelData

                    objectName: "cliproxyapiUsage:" + modelData.account
                    Layout.fillWidth: true
                    text: {
                        const parts = [row.modelData.day, row.modelData.account, row.modelData.model, qsTr("%n request(s)", "", row.modelData.requests), qsTr("%1 tokens").arg(page.tokens(row.modelData.totalTokens))];
                        if (row.modelData.failed > 0)
                            parts.push(qsTr("%n failed", "", row.modelData.failed));
                        return parts.join(" · ");
                    }
                    color: page.foreground
                    wrapMode: page.narrow ? Text.Wrap : Text.NoWrap
                    elide: page.narrow ? Text.ElideNone : Text.ElideRight
                    font.pixelSize: Theme.type.meta.size
                }
            }

            // --- upstream API keys ---
            Rule {}

            Heading {
                text: qsTr("API keys")
            }

            Note {
                text: qsTr("Keys the proxy sends upstream, besides the accounts above. They are kept in the proxy's config on this machine and shown masked.")
            }

            Repeater {
                model: page.keys

                delegate: RowLayout {
                    id: key

                    required property var modelData

                    objectName: "cliproxyapiKey:" + modelData.provider + ":" + modelData.index
                    Layout.fillWidth: true
                    spacing: 8

                    Text {
                        Layout.fillWidth: true
                        text: [page.providerLabel(key.modelData.provider), (key.modelData.keys ?? []).join(", "), key.modelData.baseUrl ?? "", key.modelData.name ?? ""].filter(part => part.length > 0).join(" · ")
                        color: page.foreground
                        elide: Text.ElideRight
                        font.pixelSize: Theme.type.meta.size
                    }

                    ShellButton {
                        objectName: "cliproxyapiRemoveKey:" + key.modelData.provider + ":" + key.modelData.index
                        subtle: true
                        destructive: true
                        text: qsTr("Remove")
                        onClicked: page.start("removeKey", {
                            provider: key.modelData.provider,
                            index: key.modelData.index,
                            keys: key.modelData.keys
                        })
                    }
                }
            }

            GridLayout {
                Layout.fillWidth: true
                columns: page.narrow ? 1 : 4
                columnSpacing: 8
                rowSpacing: 6

                ShellComboBox {
                    id: provider

                    objectName: "cliproxyapiKeyProvider"
                    outline: true
                    Layout.preferredWidth: page.narrow ? -1 : 120
                    Layout.fillWidth: page.narrow
                    model: [qsTr("Claude"), qsTr("Codex"), qsTr("Gemini")]
                    Accessible.name: qsTr("Provider")
                }

                ShellTextField {
                    id: apiKey

                    objectName: "cliproxyapiKeyValue"
                    Layout.fillWidth: true
                    echoMode: TextInput.Password
                    placeholderText: qsTr("API key")
                    Accessible.name: qsTr("API key")
                }

                ShellTextField {
                    id: baseUrl

                    objectName: "cliproxyapiKeyBase"
                    Layout.fillWidth: true
                    placeholderText: qsTr("Base URL (optional)")
                    Accessible.name: qsTr("Base URL")
                }

                ShellButton {
                    objectName: "cliproxyapiAddKey"
                    enabled: page.running && apiKey.text.trim().length > 0
                    text: qsTr("Add key")
                    onClicked: page.start("addKey", {
                        provider: ["claude", "codex", "gemini"][provider.currentIndex],
                        apiKey: apiKey.text,
                        baseUrl: baseUrl.text
                    }, () => {
                        apiKey.clear();
                        baseUrl.clear();
                    })
                }
            }

            // --- the log ---
            Rule {}

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Heading {
                    text: qsTr("Log")
                }

                ShellButton {
                    objectName: "cliproxyapiClearLogs"
                    subtle: true
                    enabled: page.running && page.logs.length > 0
                    text: qsTr("Clear")
                    onClicked: page.start("clearLogs", {})
                }
            }

            Text {
                objectName: "cliproxyapiLog"
                Layout.fillWidth: true
                text: page.logs.length > 0 ? page.logs.join("\n") : (page.status?.output ?? []).join("\n")
                color: page.muted
                wrapMode: Text.WrapAnywhere
                font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
                font.pixelSize: Theme.type.caption.size
                textFormat: Text.PlainText
            }
        }
    }
}
