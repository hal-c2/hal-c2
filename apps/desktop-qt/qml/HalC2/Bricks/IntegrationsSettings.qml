pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → Integrations, natively (DeviceSettingsController's
// `deviceSettings`): the device hub and agent device access on the selected
// environments, and one environment's device status. Then the environment's
// Slack connection (SlackSettingsController's `slackSettings`), which its
// plugins post and listen through.
SettingsPage {
    id: page

    readonly property var settings: Shell.state.deviceSettings ?? null
    readonly property var slack: Shell.state.slackSettings ?? null
    readonly property bool slackIdle: (slack?.pending ?? "") === ""
    readonly property bool idle: (settings?.pending ?? "") === ""
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color warning: Theme.palette.color("warning", "#fbbf24")
    readonly property color danger: Theme.palette.color("error", "#ef4444")

    function send(name, payload) {
        Shell.dispatch("deviceSettings." + name, payload ?? {});
    }

    objectName: "integrationsSettings"
    title: qsTr("Integrations")

    component Caption: Label {
        Layout.fillWidth: true
        color: Theme.palette.color("textMuted", "#a1a1aa")
        font.pixelSize: Math.round(12 * Theme.fontScale)
        wrapMode: Text.Wrap
    }

    // The hub or agent access: its switch, the tool's version, and an update
    // when one is offered. An inline component cannot see `page`: it is
    // handed the page's settings and colours.
    component Toggle: ColumnLayout {
        id: toggle

        property string tool
        property string title
        property string description
        required property var settings
        required property color foreground
        required property color muted
        required property color warning
        required property color danger
        readonly property bool idle: (settings?.pending ?? "") === ""
        readonly property var entry: settings?.[tool] ?? null

        function send(name, payload) {
            Shell.dispatch("deviceSettings." + name, payload ?? {});
        }

        objectName: tool
        Layout.fillWidth: true
        spacing: 4

        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                Label {
                    text: toggle.title
                    color: toggle.foreground
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                    font.weight: Font.Medium
                }

                Label {
                    objectName: "mixed"
                    visible: toggle.entry?.mixed ?? false
                    text: qsTr("Mixed across selected machines")
                    color: toggle.warning
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }

                Caption {
                    text: toggle.description
                }
            }

            Label {
                objectName: "version"
                text: toggle.entry?.version ?? ""
                color: toggle.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
                font.family: "monospace"
            }

            Label {
                objectName: "status"
                visible: text.length > 0
                text: toggle.entry?.status ?? ""
                color: toggle.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }

            ShellSwitch {
                objectName: "control"
                enabled: toggle.entry?.enabled ?? false
                checked: toggle.entry?.on ?? false
                Accessible.name: toggle.title
                onToggled: toggle.send(toggle.tool, { enabled: checked })
            }
        }

        RowLayout {
            spacing: 8
            visible: update.visible || check.visible

            ShellButton {
                id: update
                objectName: "update"
                visible: (toggle.entry?.update ?? "") !== ""
                enabled: toggle.idle && !(toggle.settings?.busy ?? false)
                text: toggle.settings?.pending === "update-" + toggle.tool ? qsTr("Updating…") : (toggle.entry?.update ?? "")
                onClicked: toggle.send("update", { tool: toggle.tool })
            }

            ShellButton {
                id: check
                objectName: "check"
                visible: toggle.settings?.canCheck ?? false
                enabled: toggle.idle && !(toggle.settings?.busy ?? false)
                subtle: true
                text: toggle.settings?.pending === "check" ? qsTr("Checking…") : qsTr("Check versions")
                onClicked: toggle.send("check")
            }
        }

        Label {
            objectName: "updateError"
            visible: toggle.settings?.updateError?.tool === toggle.tool
            Layout.fillWidth: true
            text: toggle.settings?.updateError?.message ?? ""
            color: toggle.danger
            font.pixelSize: Math.round(12 * Theme.fontScale)
            wrapMode: Text.Wrap
        }
    }

    SettingsScopeSentence {}

    Label {
        text: qsTr("Devices")
        color: page.muted
        font.pixelSize: Math.round(12 * Theme.fontScale)
        font.weight: Font.DemiBold
    }

    Toggle {
        settings: page.settings
        foreground: page.foreground
        muted: page.muted
        warning: page.warning
        danger: page.danger
        tool: "hub"
        title: qsTr("Device hub")
        description: qsTr("Enable this environment to open simulators and emulators, whether they run here or on a remote device host.")
    }

    ColumnLayout {
        objectName: "platforms"
        visible: (page.settings?.platforms ?? []).length > 0
        Layout.fillWidth: true
        spacing: 6

        RowLayout {
            Layout.fillWidth: true

            Caption {
                objectName: "statusNote"
                visible: text.length > 0
                text: page.settings?.statusNote ?? ""
            }

            Item {
                Layout.fillWidth: true
            }

            ShellButton {
                objectName: "refresh"
                subtle: true
                enabled: page.idle && (page.settings?.hub?.on ?? false) && !(page.settings?.busy ?? false)
                text: page.settings?.pending === "check" ? qsTr("Checking…") : qsTr("Refresh")
                onClicked: page.send("refresh")
            }
        }

        Repeater {
            model: page.settings?.platforms ?? []

            delegate: RowLayout {
                id: platform

                required property var modelData
                objectName: "platform:" + platform.modelData.platform
                Layout.fillWidth: true
                spacing: 8

                Label {
                    text: platform.modelData.platform
                    color: page.foreground
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                    font.weight: Font.Medium
                }

                Caption {
                    objectName: "message"
                    text: platform.modelData.ready ? qsTr("Ready") : platform.modelData.message
                }
            }
        }
    }

    Toggle {
        settings: page.settings
        foreground: page.foreground
        muted: page.muted
        warning: page.warning
        danger: page.danger
        tool: "agent"
        title: qsTr("Agent device access")
        description: qsTr("Allow new agent sessions in this environment to start and control local and remote devices, with required tools set up automatically.")
    }

    Repeater {
        model: page.settings?.hosts ?? []

        delegate: RowLayout {
            id: host

            required property var modelData
            objectName: "host:" + host.modelData.id
            Layout.fillWidth: true
            spacing: 12

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                Label {
                    text: host.modelData.label
                    color: page.foreground
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    font.weight: Font.Medium
                }

                Caption {
                    text: host.modelData.message
                }

                Caption {
                    visible: host.modelData.failed
                    text: qsTr("Check the host connection and network access, then retry. Your device settings are saved.")
                }
            }

            ShellButton {
                objectName: "retry"
                visible: host.modelData.canRetry
                enabled: page.idle
                text: page.settings?.pending === "retry" ? qsTr("Retrying…") : qsTr("Retry")
                onClicked: page.send("retry", { hostId: host.modelData.id })
            }
        }
    }

    Label {
        Layout.topMargin: 12
        text: qsTr("Slack")
        color: page.muted
        font.pixelSize: Math.round(12 * Theme.fontScale)
        font.weight: Font.DemiBold
    }

    // The tokens are sent once and cleared: the MC keeps them, and the page
    // only learns that they are set.
    ColumnLayout {
        id: slackSection

        function connectSlack() {
            Shell.dispatch("slackSettings.connect", { botToken: slackBot.text, appToken: slackApp.text });
            slackBot.clear();
            slackApp.clear();
        }

        objectName: "slack"
        Layout.fillWidth: true
        spacing: 8

        Caption {
            text: qsTr("Connect this environment to one Slack workspace. Plugins you allow to read or write Slack use it to post, follow threads and answer their own slash commands.")
        }

        Caption {
            objectName: "slackStatusNote"
            visible: text.length > 0
            text: page.slack?.statusNote ?? ""
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            Label {
                objectName: "slackStatus"
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: page.slack?.state === "failed" || (page.slack?.failed ?? false) ? page.danger : page.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
                text: {
                    if (page.slack?.failed ?? false)
                        return qsTr("Could not load Slack");
                    switch (page.slack?.state ?? "off") {
                    case "connected":
                        return qsTr("Connected to %1 as %2").arg(page.slack.team).arg(page.slack.bot);
                    case "connecting":
                        return qsTr("Connecting…");
                    case "reconnecting":
                        return qsTr("Reconnecting…");
                    case "failed":
                        return qsTr("Not connected");
                    default:
                        return (page.slack?.loaded ?? false) ? qsTr("Not connected") : qsTr("Loading…");
                    }
                }
            }

            ShellButton {
                objectName: "slackRetry"
                visible: page.slack?.failed ?? false
                text: qsTr("Try again")
                onClicked: Shell.dispatch("slackSettings.retry", {})
            }

            ShellButton {
                objectName: "slackCopyManifest"
                subtle: true
                enabled: page.slackIdle && (page.slack?.loaded ?? false)
                text: page.slack?.pending === "manifest" ? qsTr("Copying…") : qsTr("Copy app manifest")
                onClicked: Shell.dispatch("slackSettings.copyManifest", {})
            }

            ShellButton {
                objectName: "slackDisconnect"
                visible: page.slack?.tokensSet ?? false
                enabled: page.slackIdle && (page.slack?.editable ?? false)
                text: page.slack?.pending === "disconnect" ? qsTr("Disconnecting…") : qsTr("Disconnect")
                onClicked: Shell.dispatch("slackSettings.disconnect", {})
            }
        }

        Label {
            objectName: "slackError"
            visible: text.length > 0
            Layout.fillWidth: true
            text: page.slack?.error ?? ""
            color: page.danger
            font.pixelSize: Math.round(12 * Theme.fontScale)
            wrapMode: Text.Wrap
        }

        Caption {
            text: qsTr("Make a Slack app from the manifest at api.slack.com/apps, install it to the workspace, and add an app-level token with connections:write. Then paste the bot token and the app token here.")
        }

        ShellTextField {
            id: slackBot
            objectName: "slackBotToken"
            Layout.fillWidth: true
            enabled: page.slack?.editable ?? false
            echoMode: TextInput.Password
            maximumLength: 512
            placeholderText: (page.slack?.tokensSet ?? false) ? qsTr("Bot token set (xoxb-…)") : qsTr("Bot token (xoxb-…)")
            Accessible.name: qsTr("Slack bot token")
            onAccepted: if (slackConnect.enabled) slackSection.connectSlack()
        }

        ShellTextField {
            id: slackApp
            objectName: "slackAppToken"
            Layout.fillWidth: true
            enabled: page.slack?.editable ?? false
            echoMode: TextInput.Password
            maximumLength: 512
            placeholderText: (page.slack?.tokensSet ?? false) ? qsTr("App token set (xapp-…)") : qsTr("App token (xapp-…)")
            Accessible.name: qsTr("Slack app token")
            onAccepted: if (slackConnect.enabled) slackSection.connectSlack()
        }

        ShellButton {
            id: slackConnect
            objectName: "slackConnect"
            enabled: page.slackIdle && (page.slack?.editable ?? false) && slackBot.text.trim().length > 0 && slackApp.text.trim().length > 0
            text: page.slack?.pending === "connect" ? qsTr("Connecting…") : ((page.slack?.tokensSet ?? false) ? qsTr("Replace tokens") : qsTr("Connect"))
            onClicked: slackSection.connectSlack()
        }
    }
}
