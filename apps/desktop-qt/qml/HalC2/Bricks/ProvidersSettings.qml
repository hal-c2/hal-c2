import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The Providers settings section (ProviderSettingsController publishes
// `providerSettings`): one environment's providers, how each stands, turning
// one on or off, signing in and out, and its version and updates.
Rectangle {
    id: page

    objectName: "providersSettings"

    readonly property var model: Shell.state.providerSettings ?? null
    readonly property var environments: model ? model.environments : []
    readonly property var providers: model ? model.providers : []
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color warning: Theme.palette.color("warning", "#f59e0b")
    readonly property color danger: Theme.palette.color("error", "#f87171")

    // The web's RedactedSensitiveText placeholder: the same length and
    // separators, other characters drawn from a hash of the value, so an
    // account can be told apart without being read.
    function redacted(value) {
        const alphabet = "abcdefghjkmnpqrstuvwxyz23456789";
        let state = 0x811c9dc5 | 0;
        for (let i = 0; i < value.length; ++i) {
            state ^= value.charCodeAt(i);
            state = Math.imul(state, 0x01000193);
        }
        let result = "";
        for (const char of value) {
            if (char === "@" || char === "." || char === "-" || char === "_") {
                result += char;
                continue;
            }
            state = Math.imul(state ^ (state >>> 13), 0x85ebca6b);
            state = Math.imul(state ^ (state >>> 16), 0xc2b2ae35);
            result += alphabet[Math.abs(state) % alphabet.length];
        }
        return result;
    }

    function act(action, provider, extra) {
        Shell.dispatch("providerSettings." + action, Object.assign({ instanceId: provider.instanceId }, extra || {}));
    }

    color: Theme.palette.color("canvas", "#0b0b0d")

    component Note: Label {
        Layout.fillWidth: true
        color: page.muted
        font.pixelSize: 12
        wrapMode: Text.Wrap
    }

    component ProviderCard: ShellCard {
        id: card

        required property var modelData
        readonly property var provider: modelData
        readonly property var account: provider.account
        readonly property var advisory: provider.advisory
        property bool revealed: false

        objectName: "provider_" + provider.instanceId
        Layout.fillWidth: true
        implicitHeight: cardColumn.implicitHeight + 24

        ColumnLayout {
            id: cardColumn

            x: 12
            y: 12
            width: parent.width - 24
            spacing: 6

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                ProviderIcon {
                    driverKind: card.provider.driver
                    size: 18
                }

                Label {
                    text: card.provider.name
                    color: page.foreground
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                }

                Label {
                    visible: card.provider.version.length > 0
                    text: card.provider.version
                    color: page.muted
                    font.pixelSize: 11
                    font.family: "monospace"
                }

                Item {
                    Layout.fillWidth: true
                }

                Switch {
                    objectName: "enabled"
                    checked: card.provider.enabled
                    Accessible.name: qsTr("Use %1 for new threads").arg(card.provider.name)
                    onToggled: page.act("enable", card.provider, { enabled: checked })
                }
            }

            Label {
                objectName: "headline"
                Layout.fillWidth: true
                text: card.provider.headline
                color: card.provider.status === "error" || card.provider.status === "warning" ? page.warning : page.foreground
                font.pixelSize: 12
                elide: Text.ElideRight
            }

            Note {
                visible: card.provider.detail.length > 0
                text: card.provider.detail
            }

            // The account email, scrambled until the user asks.
            Button {
                id: email

                objectName: "email"
                visible: card.provider.email.length > 0
                flat: true
                padding: 0
                text: card.revealed ? card.provider.email : page.redacted(card.provider.email)
                font.pixelSize: 11
                font.family: "monospace"
                Accessible.name: qsTr("Toggle account email visibility")
                ToolTip.visible: hovered
                ToolTip.text: card.revealed ? qsTr("Hide account email") : qsTr("Show account email")
                onClicked: card.revealed = !card.revealed

                contentItem: Label {
                    text: email.text
                    color: email.hovered ? page.foreground : page.muted
                    font: email.font
                }
                background: null
            }

            // The version outside the supported range, or an update.
            ColumnLayout {
                objectName: "advisory"
                Layout.fillWidth: true
                visible: card.advisory !== null
                spacing: 4

                Label {
                    Layout.fillWidth: true
                    text: card.advisory ? card.advisory.title : ""
                    color: card.advisory && card.advisory.strong ? page.warning : page.foreground
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                }

                Note {
                    text: card.advisory ? card.advisory.detail : ""
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    ShellButton {
                        objectName: "update"
                        visible: card.provider.canUpdate || card.provider.updating
                        enabled: !card.provider.updating
                        text: card.provider.updating ? qsTr("Updating…") : qsTr("Update now")
                        onClicked: page.act("update", card.provider)
                    }

                    Label {
                        Layout.fillWidth: true
                        visible: !!(card.advisory && card.advisory.updateCommand)
                        text: card.advisory && card.advisory.updateCommand ? card.advisory.updateCommand : ""
                        color: page.muted
                        font.pixelSize: 11
                        font.family: "monospace"
                        elide: Text.ElideMiddle
                    }

                    ShellButton {
                        visible: !!(card.advisory && card.advisory.updateCommand)
                        subtle: true
                        text: qsTr("Copy")
                        Accessible.name: qsTr("Copy the update command")
                        onClicked: page.act("copyUpdateCommand", card.provider)
                    }
                }
            }

            // Signing in from HAL-C2, for providers that can.
            ColumnLayout {
                objectName: "account"
                Layout.fillWidth: true
                visible: card.account !== null
                spacing: 4

                Note {
                    text: card.account ? card.account.description : ""
                }

                Note {
                    visible: !!(card.account && card.account.userCode)
                    text: card.account ? qsTr("Code: %1").arg(card.account.userCode) : ""
                    color: page.foreground
                }

                Note {
                    visible: !!(card.account && card.account.error)
                    text: card.account ? card.account.error : ""
                    color: page.danger
                }

                RowLayout {
                    spacing: 8

                    ShellButton {
                        objectName: "signIn"
                        visible: card.account !== null && !card.account.canCancel
                        enabled: card.account !== null && card.account.canSignIn
                        text: card.account ? card.account.signInLabel : ""
                        onClicked: page.act("signIn", card.provider)
                    }

                    ShellButton {
                        visible: !!(card.account && card.account.url)
                        primary: true
                        text: qsTr("Open sign-in page")
                        onClicked: page.act("openSignIn", card.provider)
                    }

                    ShellButton {
                        visible: card.account !== null && card.account.canCancel
                        subtle: true
                        text: qsTr("Cancel")
                        onClicked: page.act("cancelSignIn", card.provider)
                    }

                    ShellButton {
                        visible: card.account !== null && card.account.canSignOut
                        subtle: true
                        text: qsTr("Sign out")
                        onClicked: page.act("signOut", card.provider)
                    }
                }
            }

            Note {
                visible: card.provider.models.length > 0
                text: qsTr("Models: %1").arg(card.provider.models.map(model => model.name || model.slug).join(", "))
                elide: Text.ElideRight
                maximumLineCount: 2
            }
        }
    }

    Flickable {
        anchors.fill: parent
        contentHeight: column.implicitHeight + 48
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: column

            x: 24
            y: 24
            width: Math.min(720, parent.width - 48)
            spacing: 8

            RowLayout {
                Layout.fillWidth: true

                Label {
                    Layout.fillWidth: true
                    text: qsTr("Providers")
                    color: page.foreground
                    font.pixelSize: 18
                    font.weight: Font.DemiBold
                }

                ShellButton {
                    objectName: "refresh"
                    enabled: page.model !== null && page.model.status === "ready" && !page.model.refreshing
                    text: page.model && page.model.refreshing ? qsTr("Refreshing…") : qsTr("Refresh")
                    onClicked: Shell.dispatch("providerSettings.refresh")
                }
            }

            // Which environment's providers: shown once there is a choice.
            Flow {
                objectName: "environments"
                Layout.fillWidth: true
                visible: page.environments.length > 1
                spacing: 6

                Repeater {
                    model: page.environments

                    delegate: ShellButton {
                        required property var modelData
                        subtle: page.model.environmentId !== modelData.id
                        primary: page.model.environmentId === modelData.id
                        text: modelData.online ? modelData.label : qsTr("%1 (offline)").arg(modelData.label)
                        onClicked: Shell.dispatch("providerSettings.environment", {
                            id: modelData.id
                        })
                    }
                }
            }

            // Why nothing is listed.
            ColumnLayout {
                objectName: "placeholder"
                Layout.fillWidth: true
                Layout.topMargin: 12
                visible: page.model !== null && page.model.title.length > 0
                spacing: 4

                Label {
                    Layout.fillWidth: true
                    text: page.model ? page.model.title : ""
                    color: page.foreground
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                }

                Note {
                    text: page.model ? page.model.description : ""
                }
            }

            Repeater {
                model: page.providers

                delegate: ProviderCard {}
            }
        }
    }
}
