import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The Providers settings section (ProviderSettingsController publishes
// `providerSettings`): one environment's providers, how each stands, turning
// one on or off, signing in and out, its version and updates, and adding,
// configuring and deleting instances.
Rectangle {
    id: page

    objectName: "providersSettings"

    readonly property var model: Shell.state.providerSettings ?? null
    readonly property var environments: model ? model.environments : []
    readonly property var providers: model ? model.providers : []
    // The session may only view this environment: nothing on it can be changed.
    readonly property bool readOnly: !!(model && model.readOnly)
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

    // A driver setting: a text or secret input, or a choice. `commit(value)`
    // runs when the user settles on a value.
    component ConfigField: ColumnLayout {
        id: configField

        required property var field
        signal commit(string value)

        objectName: "field_" + field.key
        Layout.fillWidth: true
        spacing: 2

        Label {
            text: configField.field.label
            color: page.foreground
            font.pixelSize: 12
            font.weight: Font.Medium
        }

        ShellTextField {
            objectName: "input"
            Layout.fillWidth: true
            visible: configField.field.control !== "select"
            text: configField.field.value
            placeholderText: configField.field.placeholder
            echoMode: configField.field.control === "password" ? TextInput.Password : TextInput.Normal
            Accessible.name: configField.field.label
            onEditingFinished: if (text !== configField.field.value) configField.commit(text)
        }

        ShellComboBox {
            objectName: "choice"
            visible: configField.field.control === "select"
            outline: true
            model: configField.field.options
            textRole: "label"
            valueRole: "value"
            currentIndex: Math.max(0, indexOfValue(configField.field.value))
            Accessible.name: configField.field.label
            onActivated: configField.commit(currentValue)
        }

        Note {
            visible: configField.field.description.length > 0
            text: configField.field.description
        }
    }

    // An accent colour as `#rrggbb`, or none.
    component AccentField: RowLayout {
        id: accentField

        required property string color
        property string name: ""
        signal commit(string color)

        objectName: "accent"
        spacing: 6

        Rectangle {
            implicitWidth: 18
            implicitHeight: 18
            radius: 9
            color: accentField.color.length > 0 ? accentField.color : "transparent"
            border.color: Theme.palette.color("border", "#27272a")
        }

        ShellTextField {
            objectName: "hex"
            implicitWidth: 110
            text: accentField.color
            placeholderText: "#2563eb"
            font.family: "monospace"
            Accessible.name: qsTr("Accent color for %1").arg(accentField.name)
            onEditingFinished: if (text !== accentField.color) accentField.commit(text)
        }

        ShellButton {
            visible: accentField.color.length > 0
            subtle: true
            text: qsTr("Clear color")
            onClicked: accentField.commit("")
        }
    }

    // Adding an instance: pick a driver, name it, then set it up.
    component Wizard: ShellCard {
        id: wizardCard

        required property var wizard

        objectName: "wizard"
        Layout.fillWidth: true
        implicitHeight: wizardColumn.implicitHeight + 24

        function send(action, payload) {
            Shell.dispatch("providerSettings.wizard" + action, payload || {});
        }

        ColumnLayout {
            id: wizardColumn

            x: 12
            y: 12
            width: parent.width - 24
            spacing: 8

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Label {
                    Layout.fillWidth: true
                    text: qsTr("Add provider instance")
                    color: page.foreground
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                }

                Repeater {
                    model: wizardCard.wizard.steps

                    delegate: Label {
                        required property string modelData
                        required property int index
                        text: (index + 1) + ". " + modelData
                        color: index === wizardCard.wizard.step ? page.foreground : page.muted
                        font.pixelSize: 11
                        font.weight: index === wizardCard.wizard.step ? Font.DemiBold : Font.Normal
                    }
                }
            }

            Flow {
                objectName: "drivers"
                Layout.fillWidth: true
                visible: wizardCard.wizard.step === 0
                spacing: 6

                Repeater {
                    model: wizardCard.wizard.drivers

                    delegate: ShellButton {
                        required property var modelData
                        objectName: "driver_" + modelData.id
                        primary: wizardCard.wizard.driver === modelData.id
                        subtle: !primary
                        text: modelData.badge ? modelData.label + " (" + modelData.badge + ")" : modelData.label
                        onClicked: wizardCard.send("Driver", { driver: modelData.id })
                    }
                }
            }

            // Or an agent from the ACP Registry, installed as it is chosen.
            ColumnLayout {
                id: registryPane

                readonly property var registry: wizardCard.wizard.registry

                function send(action, payload) {
                    Shell.dispatch("providerSettings.registry" + action, payload || {});
                }

                objectName: "registry"
                Layout.fillWidth: true
                visible: wizardCard.wizard.step === 0
                spacing: 6

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    Label {
                        Layout.fillWidth: true
                        text: qsTr("Or choose from ACP Registry")
                        color: page.foreground
                        font.pixelSize: 12
                        font.weight: Font.Medium
                    }

                    ShellButton {
                        objectName: "registryManual"
                        primary: registryPane.registry.manual
                        subtle: !primary
                        enabled: !registryPane.registry.busy
                        text: qsTr("Enter manually")
                        onClicked: registryPane.send("Manual", { manual: !registryPane.registry.manual })
                    }
                }

                ShellTextField {
                    id: registryQuery

                    objectName: "registryQuery"
                    Layout.fillWidth: true
                    visible: !registryPane.registry.manual
                    placeholderText: qsTr("Search ACP agents")
                    Accessible.name: qsTr("Search the ACP Registry")
                    onTextEdited: registryDebounce.restart()
                    onAccepted: {
                        registryDebounce.stop();
                        registryPane.send("Search", { query: text });
                    }
                }

                Timer {
                    id: registryDebounce

                    interval: 300
                    onTriggered: registryPane.send("Search", { query: registryQuery.text })
                }

                Note {
                    visible: !registryPane.registry.manual && registryPane.registry.agents === null && registryPane.registry.searching
                    text: qsTr("Searching…")
                }

                ColumnLayout {
                    objectName: "registryEmpty"
                    visible: !registryPane.registry.manual && registryPane.registry.agents !== null && registryPane.registry.agents.length === 0
                    spacing: 2

                    Label {
                        text: qsTr("No compatible agents found")
                        color: page.foreground
                        font.pixelSize: 12
                    }

                    Note {
                        text: qsTr("Try a broader search.")
                    }
                }

                Repeater {
                    model: registryPane.registry.manual ? [] : (registryPane.registry.agents ?? [])

                    delegate: RowLayout {
                        id: agentRow

                        required property var modelData
                        objectName: "registryAgent_" + modelData.id
                        Layout.fillWidth: true
                        spacing: 8

                        Image {
                            Layout.preferredWidth: 20
                            Layout.preferredHeight: 20
                            visible: agentRow.modelData.iconUrl.length > 0
                            source: agentRow.modelData.iconUrl
                            sourceSize: Qt.size(20, 20)
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            Label {
                                Layout.fillWidth: true
                                text: agentRow.modelData.name
                                color: page.foreground
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }

                            Note {
                                visible: text.length > 0
                                text: agentRow.modelData.description
                                maximumLineCount: 2
                                elide: Text.ElideRight
                            }
                        }

                        ShellButton {
                            objectName: "registryAdd"
                            primary: !agentRow.modelData.added
                            subtle: agentRow.modelData.added
                            enabled: !agentRow.modelData.added && !registryPane.registry.busy
                            text: agentRow.modelData.added ? qsTr("Added") : agentRow.modelData.preparing ? agentRow.modelData.progress + "…" : qsTr("Add")
                            onClicked: registryPane.send("Add", { agentId: agentRow.modelData.id })
                        }
                    }
                }

                Note {
                    objectName: "registryError"
                    visible: text.length > 0
                    text: registryPane.registry.error.length > 0 ? registryPane.registry.error : registryPane.registry.selectionError
                    color: page.danger
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                visible: wizardCard.wizard.step === 1
                spacing: 6

                Label {
                    text: qsTr("Label")
                    color: page.foreground
                    font.pixelSize: 12
                }

                ShellTextField {
                    objectName: "label"
                    Layout.fillWidth: true
                    text: wizardCard.wizard.label
                    placeholderText: wizardCard.wizard.driverLabel
                    onTextEdited: wizardCard.send("Label", { label: text })
                }

                AccentField {
                    color: wizardCard.wizard.accentColor
                    name: wizardCard.wizard.label
                    onCommit: color => wizardCard.send("Accent", { color: color })
                }

                Label {
                    text: qsTr("Instance ID")
                    color: page.foreground
                    font.pixelSize: 12
                }

                ShellTextField {
                    objectName: "instanceId"
                    Layout.fillWidth: true
                    text: wizardCard.wizard.instanceId
                    font.family: "monospace"
                    onTextEdited: wizardCard.send("InstanceId", { instanceId: text })
                }

                Note {
                    objectName: "instanceIdError"
                    visible: wizardCard.wizard.instanceIdError.length > 0
                    text: wizardCard.wizard.instanceIdError
                    color: page.danger
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                visible: wizardCard.wizard.step === 2
                spacing: 8

                Note {
                    visible: wizardCard.wizard.fields.length === 0
                    text: qsTr("%1 needs no further setup.").arg(wizardCard.wizard.driverLabel)
                }

                Repeater {
                    model: wizardCard.wizard.fields

                    delegate: ConfigField {
                        required property var modelData
                        field: modelData
                        onCommit: value => wizardCard.send("Field", { key: modelData.key, value: value })
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                ShellButton {
                    subtle: true
                    enabled: !wizardCard.wizard.saving
                    text: qsTr("Cancel")
                    onClicked: wizardCard.send("Close")
                }

                Item {
                    Layout.fillWidth: true
                }

                ShellButton {
                    objectName: "back"
                    visible: wizardCard.wizard.step > 0
                    enabled: !wizardCard.wizard.saving
                    text: qsTr("Back")
                    onClicked: wizardCard.send("Step", { step: wizardCard.wizard.step - 1 })
                }

                ShellButton {
                    objectName: "next"
                    visible: wizardCard.wizard.step < wizardCard.wizard.steps.length - 1
                    primary: true
                    text: qsTr("Next")
                    onClicked: wizardCard.send("Step", { step: wizardCard.wizard.step + 1 })
                }

                ShellButton {
                    objectName: "submit"
                    primary: true
                    enabled: !wizardCard.wizard.saving
                    text: wizardCard.wizard.saving ? qsTr("Adding…") : qsTr("Add instance")
                    onClicked: wizardCard.send("Submit")
                }
            }
        }
    }

    component ProviderCard: ShellCard {
        id: card

        required property var modelData
        readonly property var provider: modelData
        readonly property var account: provider.account
        readonly property var advisory: provider.advisory
        property bool revealed: false
        property bool configuring: false

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

                Rectangle {
                    visible: card.provider.accentColor.length > 0
                    implicitWidth: 8
                    implicitHeight: 8
                    radius: 4
                    color: card.provider.accentColor.length > 0 ? card.provider.accentColor : "transparent"
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

                ShellButton {
                    objectName: "configure"
                    visible: card.provider.editable
                    subtle: true
                    iconName: "settings"
                    Accessible.name: qsTr("Configure %1").arg(card.provider.name)
                    onClicked: card.configuring = !card.configuring
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
                        readonly property bool install: (card.provider.installLabel ?? "").length > 0
                        visible: card.provider.canUpdate || install || card.provider.updating
                        enabled: !card.provider.updating
                        text: card.provider.updating ? qsTr("Updating…") : install ? card.provider.installLabel : qsTr("Update now")
                        onClicked: page.act(install ? "install" : "update", card.provider)
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
                    text: card.account ? qsTr("Enter code %1 in your browser.").arg(card.account.userCode) : ""
                    color: page.foreground
                }

                Note {
                    visible: !!(card.account && card.account.error)
                    text: card.account ? card.account.error : ""
                    color: page.danger
                }

                RowLayout {
                    spacing: 8

                    ShellComboBox {
                        id: method

                        objectName: "signInMethod"
                        readonly property var methods: card.account && card.account.methods ? card.account.methods : []
                        visible: methods.length > 1
                        outline: true
                        model: [{ id: "", name: qsTr("Provider default") }].concat(methods)
                        textRole: "name"
                        valueRole: "id"
                        Accessible.name: qsTr("Sign-in method")
                    }

                    ShellButton {
                        objectName: "signIn"
                        visible: card.account !== null && !card.account.canCancel
                        enabled: card.account !== null && card.account.canSignIn
                        text: card.account ? card.account.signInLabel : ""
                        onClicked: page.act("signIn", card.provider, method.currentValue ? { methodId: method.currentValue } : {})
                    }

                    ShellButton {
                        visible: !!(card.account && card.account.url)
                        primary: true
                        text: qsTr("Open sign-in page")
                        onClicked: page.act("openSignIn", card.provider)
                    }

                    ShellButton {
                        visible: !!(card.account && card.account.url)
                        subtle: true
                        iconName: "copy"
                        Accessible.name: qsTr("Copy sign-in link")
                        ToolTip.visible: hovered
                        ToolTip.text: qsTr("Copy sign-in link")
                        onClicked: page.act("copySignInLink", card.provider)
                    }

                    ShellButton {
                        visible: !!(card.account && card.account.docsUrl)
                        text: qsTr("Open docs")
                        onClicked: page.act("openDocs", card.provider)
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

                // The agent's login terminal, while a sign-in runs in one.
                Loader {
                    Layout.fillWidth: true
                    active: !!(card.account && card.account.terminal)
                    visible: active
                    source: active ? "ProviderAuthTerminal.qml" : ""
                    onLoaded: {
                        item.instanceId = Qt.binding(() => card.provider.instanceId);
                        item.terminal = Qt.binding(() => card.account ? card.account.terminal : null);
                    }
                }

                // The credentials the agent asks for.
                ColumnLayout {
                    id: credentials

                    objectName: "credentials"
                    readonly property var fields: card.account && card.account.credentials ? card.account.credentials : []
                    property var values: ({})
                    Layout.fillWidth: true
                    visible: fields.length > 0
                    spacing: 4

                    Repeater {
                        model: credentials.fields

                        delegate: ColumnLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: 2

                            Label {
                                text: modelData.label || modelData.name
                                color: page.foreground
                                font.pixelSize: 12
                            }

                            ShellTextField {
                                objectName: "credential_" + modelData.name
                                Layout.fillWidth: true
                                echoMode: modelData.secret ? TextInput.Password : TextInput.Normal
                                maximumLength: 16384
                                Accessible.name: modelData.label || modelData.name
                                onTextEdited: credentials.values[modelData.name] = text
                                onAccepted: connect.clicked()
                            }
                        }
                    }

                    ShellButton {
                        id: connect

                        objectName: "connect"
                        text: qsTr("Connect")
                        onClicked: {
                            page.act("signInCredentials", card.provider, { values: credentials.values });
                            credentials.values = {};
                        }
                    }
                }

                // The final localhost address, when its page does not load.
                ColumnLayout {
                    objectName: "callback"
                    Layout.fillWidth: true
                    visible: !!(card.account && card.account.acceptsCallback)
                    spacing: 4

                    Note {
                        text: qsTr("If the final localhost page does not load, paste its full URL here.")
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        ShellTextField {
                            id: callbackUrl

                            Layout.fillWidth: true
                            maximumLength: 16384
                            Accessible.name: qsTr("Final sign-in address")
                            onAccepted: continueButton.clicked()
                        }

                        ShellButton {
                            id: continueButton

                            enabled: callbackUrl.text.trim().length > 0
                            text: qsTr("Continue")
                            onClicked: {
                                page.act("signInCallback", card.provider, { url: callbackUrl.text });
                                callbackUrl.text = "";
                            }
                        }
                    }
                }
            }

            // The instance's own settings, saved as each one settles.
            ColumnLayout {
                objectName: "editor"
                Layout.fillWidth: true
                Layout.topMargin: 6
                visible: card.configuring && card.provider.editable
                spacing: 8

                Label {
                    text: qsTr("Name")
                    color: page.foreground
                    font.pixelSize: 12
                    font.weight: Font.Medium
                }

                ShellTextField {
                    objectName: "name"
                    Layout.fillWidth: true
                    text: card.provider.label
                    placeholderText: card.provider.placeholder
                    Accessible.name: qsTr("Name for %1").arg(card.provider.name)
                    onEditingFinished: if (text !== card.provider.label) page.act("rename", card.provider, { name: text })
                }

                AccentField {
                    color: card.provider.accentColor
                    name: card.provider.name
                    onCommit: color => page.act("accent", card.provider, { color: color })
                }

                Repeater {
                    model: card.provider.fields

                    delegate: ConfigField {
                        required property var modelData
                        field: modelData
                        onCommit: value => page.act("field", card.provider, { key: modelData.key, value: value })
                    }
                }

                Repeater {
                    model: card.provider.secrets

                    delegate: ColumnLayout {
                        required property var modelData
                        objectName: "secret_" + modelData.name
                        Layout.fillWidth: true
                        spacing: 2

                        Label {
                            text: modelData.label
                            color: page.foreground
                            font.pixelSize: 12
                            font.weight: Font.Medium
                        }

                        ShellTextField {
                            Layout.fillWidth: true
                            echoMode: TextInput.Password
                            placeholderText: modelData.stored ? qsTr("Stored secret, enter a new value to replace") : modelData.placeholder
                            Accessible.name: modelData.label
                            onEditingFinished: if (text.length > 0) {
                                page.act("secret", card.provider, { name: modelData.name, value: text });
                                text = "";
                            }
                        }

                        Note {
                            visible: modelData.description.length > 0
                            text: modelData.description
                        }
                    }
                }

                ProviderCustomModels {
                    Layout.fillWidth: true
                    visible: card.provider.takesModels ?? false
                    provider: card.provider
                }

                ProviderAcpSessions {
                    Layout.fillWidth: true
                    provider: card.provider
                }

                Label {
                    text: qsTr("Environment variables")
                    color: page.foreground
                    font.pixelSize: 12
                    font.weight: Font.Medium
                }

                Repeater {
                    model: card.provider.variables

                    delegate: RowLayout {
                        id: variableRow

                        required property var modelData
                        required property int index
                        objectName: "variable_" + index
                        Layout.fillWidth: true
                        spacing: 6

                        ShellTextField {
                            objectName: "variableName"
                            Layout.preferredWidth: 180
                            text: variableRow.modelData.name
                            placeholderText: "NAME"
                            font.family: "monospace"
                            color: variableRow.modelData.invalid ? page.danger : page.foreground
                            Accessible.name: qsTr("Environment variable name")
                            onEditingFinished: if (text !== variableRow.modelData.name) page.act("variable", card.provider, { index: variableRow.index, name: text })
                        }

                        ShellTextField {
                            objectName: "variableValue"
                            Layout.fillWidth: true
                            text: variableRow.modelData.value
                            placeholderText: variableRow.modelData.placeholder
                            echoMode: variableRow.modelData.sensitive ? TextInput.Password : TextInput.Normal
                            Accessible.name: qsTr("Environment variable value")
                            onEditingFinished: if (text !== variableRow.modelData.value) page.act("variable", card.provider, { index: variableRow.index, value: text })
                        }

                        ShellButton {
                            objectName: "sensitive"
                            subtle: true
                            iconName: variableRow.modelData.sensitive ? "lock" : "lock-open"
                            Accessible.name: variableRow.modelData.sensitive ? qsTr("Mark as not sensitive") : qsTr("Mark as sensitive")
                            onClicked: page.act("variable", card.provider, { index: variableRow.index, sensitive: !variableRow.modelData.sensitive })
                        }

                        ShellButton {
                            objectName: "removeVariable"
                            subtle: true
                            iconName: "x"
                            Accessible.name: qsTr("Remove environment variable")
                            onClicked: page.act("removeVariable", card.provider, { index: variableRow.index })
                        }
                    }
                }

                ShellButton {
                    objectName: "addVariable"
                    subtle: true
                    iconName: "plus"
                    text: qsTr("Add variable")
                    onClicked: page.act("addVariable", card.provider)
                }

                Note {
                    text: qsTr("Sensitive values are stored separately and never returned to the app.")
                }

                RowLayout {
                    spacing: 8

                    ShellButton {
                        objectName: "delete"
                        visible: card.provider.custom
                        subtle: true
                        tint: page.danger
                        text: qsTr("Delete instance")
                        onClicked: page.act("delete", card.provider)
                    }

                    ShellButton {
                        objectName: "resetInstance"
                        visible: card.provider.resettable
                        subtle: true
                        text: qsTr("Reset to defaults")
                        onClicked: page.act("reset", card.provider)
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
                    objectName: "addInstance"
                    enabled: page.model !== null && page.model.status === "ready" && !page.model.wizard && !page.readOnly
                    iconName: "plus"
                    text: qsTr("Add provider")
                    onClicked: Shell.dispatch("providerSettings.wizardOpen")
                }

                ShellButton {
                    objectName: "refresh"
                    enabled: page.model !== null && page.model.status === "ready" && !page.model.refreshing && !page.readOnly
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

            ColumnLayout {
                objectName: "readOnly"
                Layout.fillWidth: true
                Layout.topMargin: 12
                visible: page.readOnly
                spacing: 4

                Label {
                    Layout.fillWidth: true
                    text: qsTr("Limited permissions")
                    color: page.foreground
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                }

                Note {
                    text: page.model ? (page.model.readOnlyDescription ?? "") : ""
                }
            }

            Loader {
                Layout.fillWidth: true
                active: !!(page.model && page.model.wizard)
                visible: active

                sourceComponent: Wizard {
                    wizard: page.model.wizard
                }
            }

            Repeater {
                model: page.providers

                delegate: ProviderCard {
                    enabled: !page.readOnly
                }
            }

            // How often the environment checks its providers in the background.
            RowLayout {
                id: healthRow

                objectName: "healthInterval"
                readonly property var health: page.model ? (page.model.health ?? null) : null
                Layout.fillWidth: true
                Layout.topMargin: 12
                visible: health !== null
                enabled: !page.readOnly
                spacing: 12

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    RowLayout {
                        spacing: 4

                        Label {
                            text: qsTr("Provider health check interval")
                            color: page.foreground
                            font.pixelSize: 13
                            font.weight: Font.Medium
                        }

                        ShellButton {
                            objectName: "reset"
                            visible: healthRow.health !== null && healthRow.health.seconds !== healthRow.health.defaultSeconds
                            subtle: true
                            iconName: "undo-2"
                            iconSize: 12
                            implicitWidth: 20
                            implicitHeight: 20
                            Accessible.name: qsTr("Reset provider health check interval to default")
                            onClicked: Shell.dispatch("providerSettings.resetHealthInterval")
                        }
                    }

                    Note {
                        text: qsTr("Refresh provider status, versions, and models in the background. Set to 0 to disable.")
                    }
                }

                SpinBox {
                    objectName: "seconds"
                    from: 0
                    to: 86400
                    stepSize: healthRow.health ? healthRow.health.step : 30
                    editable: true
                    value: healthRow.health ? healthRow.health.seconds : 0
                    Accessible.name: qsTr("Provider health check interval in seconds")
                    onValueModified: Shell.dispatch("providerSettings.healthInterval", {
                        seconds: value
                    })
                }

                Label {
                    text: qsTr("seconds")
                    color: page.muted
                    font.pixelSize: 12
                }
            }

            // CLIProxyAPI hubs whose accounts join Limits.
            ColumnLayout {
                id: hubsSection

                objectName: "hubs"
                readonly property var hubs: page.model ? (page.model.hubs ?? null) : null
                Layout.fillWidth: true
                Layout.topMargin: 12
                visible: hubs !== null
                spacing: 6

                RowLayout {
                    Layout.fillWidth: true

                    Label {
                        Layout.fillWidth: true
                        text: qsTr("Usage providers")
                        color: page.foreground
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                    }

                    ShellButton {
                        objectName: "addHub"
                        visible: !page.readOnly
                        iconName: "plus"
                        text: qsTr("Add hub")
                        onClicked: addHubDialog.open()
                    }
                }

                Note {
                    visible: (hubsSection.hubs ?? []).length === 0
                    text: qsTr("No usage providers configured.")
                }

                Repeater {
                    model: hubsSection.hubs ?? []

                    delegate: RowLayout {
                        required property var modelData
                        objectName: "hub_" + modelData.id
                        Layout.fillWidth: true
                        spacing: 12

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2

                            Label {
                                objectName: "label"
                                text: modelData.label
                                color: page.foreground
                                font.pixelSize: 13
                                font.weight: Font.Medium
                            }

                            Note {
                                text: modelData.description
                                wrapMode: Text.WrapAnywhere
                            }
                        }

                        ShellButton {
                            objectName: "remove"
                            visible: !page.readOnly
                            subtle: true
                            text: qsTr("Remove")
                            onClicked: {
                                removeHubDialog.hubId = modelData.id;
                                removeHubDialog.label = modelData.label;
                                removeHubDialog.open();
                            }
                        }
                    }
                }
            }
        }
    }

    component HubDialog: Dialog {
        id: hubDialog

        parent: Overlay.overlay
        modal: true
        anchors.centerIn: parent
        width: Math.min(460, (parent?.width ?? 492) - 32)
        padding: 20

        background: Rectangle {
            color: Theme.palette.color("surfaceOverlay", "#18181b")
            border.color: Theme.palette.color("border", "#27272a")
            radius: Math.min(Theme.radius, 16)
        }
        header: Label {
            text: hubDialog.title
            padding: 20
            bottomPadding: 4
            font.pixelSize: 17
            font.weight: Font.DemiBold
            color: page.foreground
            elide: Text.ElideRight
        }
    }

    // As AddUsageLimitSourceDialog: a URL and a management key are needed.
    HubDialog {
        id: addHubDialog

        readonly property bool complete: hubUrl.text.trim().length > 0 && hubKey.text.trim().length > 0

        objectName: "addHubDialog"
        title: qsTr("Add a CLIProxyAPI hub")
        onAboutToShow: {
            hubUrl.clear();
            hubKey.clear();
            hubLabel.clear();
        }
        onAccepted: Shell.dispatch("providerSettings.addHub", {
            url: hubUrl.text.trim(),
            key: hubKey.text.trim(),
            label: hubLabel.text.trim()
        })

        contentItem: ColumnLayout {
            spacing: 8

            Note {
                text: qsTr("Its accounts' limits appear in Usage next to this machine's. The management key is kept on the server and never shown again.")
            }

            Label { text: qsTr("Hub URL"); color: page.foreground; font.pixelSize: 13 }
            TextField {
                id: hubUrl
                objectName: "url"
                Layout.fillWidth: true
                placeholderText: "https://hub.example.ts.net:8318"
                Accessible.name: qsTr("Hub URL")
            }

            Label { text: qsTr("Management key"); color: page.foreground; font.pixelSize: 13 }
            TextField {
                id: hubKey
                objectName: "key"
                Layout.fillWidth: true
                echoMode: TextInput.Password
                Accessible.name: qsTr("Management key")
            }

            Label { text: qsTr("Label (optional)"); color: page.foreground; font.pixelSize: 13 }
            TextField {
                id: hubLabel
                objectName: "label"
                Layout.fillWidth: true
                placeholderText: qsTr("Defaults to the hub's host name")
                Accessible.name: qsTr("Hub label")
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 4
                spacing: 8

                Item { Layout.fillWidth: true }

                ShellButton {
                    objectName: "cancel"
                    subtle: true
                    text: qsTr("Cancel")
                    onClicked: addHubDialog.reject()
                }

                ShellButton {
                    objectName: "confirm"
                    primary: true
                    enabled: addHubDialog.complete
                    text: qsTr("Add hub")
                    onClicked: addHubDialog.accept()
                }
            }
        }
    }

    HubDialog {
        id: removeHubDialog

        property string hubId
        property string label

        objectName: "removeHubDialog"
        title: qsTr("Remove %1?").arg(label)
        onAccepted: Shell.dispatch("providerSettings.removeHub", { id: hubId })

        contentItem: ColumnLayout {
            spacing: 12

            Note {
                text: qsTr("The hub's management key is deleted from this server. Its accounts leave the Limits view; the hub itself is untouched. Add it again with the URL and key to bring them back.")
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Item { Layout.fillWidth: true }

                ShellButton {
                    objectName: "cancel"
                    subtle: true
                    text: qsTr("Cancel")
                    onClicked: removeHubDialog.reject()
                }

                ShellButton {
                    objectName: "confirm"
                    tint: page.danger
                    text: qsTr("Remove hub")
                    onClicked: removeHubDialog.accept()
                }
            }
        }
    }
}
