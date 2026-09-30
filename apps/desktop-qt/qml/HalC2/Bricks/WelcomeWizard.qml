import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The first-run gate and the welcome wizard (the web's FirstRunGate and
// WelcomeWizard), drawn from `onboarding` (OnboardingController): nothing once
// the app opens, a blank window until the node confirms the workspace, the
// recovery page when it cannot, and otherwise the three steps (Connect,
// Agents, Projects) over the whole window.
Item {
    id: wizard

    readonly property var onboarding: Shell.state.onboarding ?? null
    readonly property string recovery: onboarding && onboarding.recovery ? onboarding.recovery : ""
    readonly property bool active: !!onboarding && (onboarding.gate !== "app" || recovery.length > 0)
    readonly property bool showWizard: active && recovery.length === 0 && onboarding.gate === "wizard"
    readonly property var importState: onboarding && onboarding.import ? onboarding.import : ({})
    readonly property bool importing: !!(onboarding && onboarding.importing)
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color border: Theme.palette.color("border", "#27272a")
    readonly property color field: Theme.palette.color("canvas", "#09090b")
    property bool pairingOpen: false
    property bool pairingHelpOpen: false

    function dispatch(action, payload) {
        Shell.dispatch(action, payload ?? {});
    }

    objectName: "welcomeWizard"
    visible: active


    Rectangle {
        anchors.fill: parent
        color: Theme.palette.color("background", "#09090b")

        // The app underneath is not there yet.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            onWheel: wheel => wheel.accepted = true
        }
    }

    // FirstRunRecovery.
    ColumnLayout {
        objectName: "onboardingRecovery"
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 384)
        visible: wizard.recovery.length > 0
        spacing: 8

        Label {
            objectName: "onboardingRecoveryTitle"
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: wizard.recovery === "settings" ? qsTr("Could not read settings") : qsTr("Still connecting")
            font.pixelSize: 18
            font.weight: Font.DemiBold
            color: wizard.foreground
        }
        Label {
            objectName: "onboardingRecoveryDetail"
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: wizard.recovery === "settings" ? qsTr("Your saved settings could not be loaded.") : qsTr("HAL-C2 could not confirm this workspace.")
            font.pixelSize: 13
            color: wizard.muted
        }
        ShellButton {
            objectName: "onboardingRecoveryAction"
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 12
            iconName: "refresh-cw"
            text: wizard.recovery === "settings" ? qsTr("Retry") : qsTr("Reload")
            onClicked: wizard.dispatch(wizard.recovery === "settings" ? "onboarding.retry" : "onboarding.reload")
        }
    }

    ShellCard {
        id: card

        objectName: "onboardingWizard"
        anchors.centerIn: parent
        width: Math.min(parent.width - 32, 576)
        height: Math.min(parent.height - 32, body.implicitHeight + 48)
        visible: wizard.showWizard
        color: Theme.palette.color("surfaceOverlay", "#18181b")

        Flickable {
            anchors.fill: parent
            anchors.margins: 24
            contentHeight: body.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: body

                width: parent.width
                spacing: 0

                // WizardHeader.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12

                    Label {
                        objectName: "onboardingTitle"
                        text: qsTr("Set up HAL-C2")
                        font.pixelSize: 13
                        color: wizard.muted
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                    HalC2Wordmark {
                        size: 14
                        Accessible.name: "HAL-C2"
                    }
                }

                // WizardSteps: back only, and not while an import runs.
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 12
                    spacing: 6

                    Repeater {
                        model: [qsTr("Connect"), qsTr("Agents"), qsTr("Projects")]

                        delegate: AbstractButton {
                            required property int index
                            required property string modelData

                            objectName: "onboardingStage" + index
                            Layout.fillWidth: true
                            implicitHeight: 28
                            enabled: !wizard.importing && index < (wizard.onboarding ? wizard.onboarding.stage : 0)
                            text: modelData
                            Accessible.name: modelData
                            onClicked: wizard.dispatch("onboarding.stage", { index: index })

                            contentItem: ColumnLayout {
                                spacing: 4
                                Rectangle {
                                    Layout.fillWidth: true
                                    implicitHeight: 3
                                    radius: 2
                                    color: index <= (wizard.onboarding ? wizard.onboarding.stage : 0)
                                        ? Theme.palette.color("accent", "#2563eb") : wizard.border
                                }
                                Label {
                                    text: modelData
                                    font.pixelSize: 11
                                    color: index === (wizard.onboarding ? wizard.onboarding.stage : 0) ? wizard.foreground : wizard.muted
                                }
                            }
                        }
                    }
                }

                Loader {
                    Layout.fillWidth: true
                    Layout.topMargin: 20
                    sourceComponent: !wizard.onboarding ? null
                        : wizard.onboarding.step === "agents" ? agentsStep
                        : wizard.onboarding.step === "import" ? importStep
                        : connectStep
                }
            }
        }
    }

    component Title: Label {
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        font.pixelSize: 22
        font.weight: Font.DemiBold
        color: wizard.foreground
    }

    component Detail: Label {
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        font.pixelSize: 13
        color: wizard.muted
    }

    component Row: Rectangle {
        Layout.fillWidth: true
        radius: 8
        color: wizard.field
        border.color: wizard.border
    }

    // ── Connect ──────────────────────────────────────────────
    Component {
        id: connectStep

        ColumnLayout {
            id: connect

            readonly property bool pairing: !!(wizard.onboarding && wizard.onboarding.pairing)

            spacing: 0
            // A pairing that worked closes the form.
            onPairingChanged: {
                if (!pairing && !wizard.onboarding.pairingError) {
                    wizard.pairingOpen = false;
                    pairingUrl.text = "";
                }
            }

            Title {
                text: qsTr("Connect your computers")
            }
            Detail {
                Layout.topMargin: 10
                text: qsTr("Choose one or more computers. We’ll set up agents and projects on each.")
            }

            Repeater {
                model: wizard.onboarding ? wizard.onboarding.computers : []

                delegate: Row {
                    id: computer

                    required property var modelData
                    required property int index

                    objectName: "onboardingComputer_" + modelData.label
                    Layout.topMargin: index === 0 ? 20 : 8
                    implicitHeight: computerRow.implicitHeight + 24

                    RowLayout {
                        id: computerRow

                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 12

                        CheckBox {
                            objectName: "onboardingComputerCheck"
                            checked: computer.modelData.selected
                            Accessible.name: computer.modelData.label
                            onToggled: wizard.dispatch("onboarding.select", {
                                environmentId: computer.modelData.environmentId,
                                selected: checked
                            })
                        }
                        ShellIcon {
                            name: "monitor"
                            size: 16
                            color: wizard.muted
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2

                            RowLayout {
                                Layout.fillWidth: true
                                Label {
                                    Layout.fillWidth: true
                                    text: computer.modelData.label
                                    wrapMode: Text.Wrap
                                    font.pixelSize: 13
                                    font.weight: Font.Medium
                                    color: wizard.foreground
                                }
                                Label {
                                    text: computer.modelData.connected ? qsTr("Connected") : qsTr("Connecting…")
                                    font.pixelSize: 11
                                    color: wizard.muted
                                }
                            }
                            Label {
                                Layout.fillWidth: true
                                visible: computer.modelData.url.length > 0
                                text: computer.modelData.url
                                wrapMode: Text.WrapAnywhere
                                font.pixelSize: 11
                                color: wizard.muted
                            }
                        }
                    }
                }
            }

            // Add a computer.
            Row {
                Layout.topMargin: 16
                implicitHeight: pairing.implicitHeight

                ColumnLayout {
                    id: pairing

                    anchors.left: parent.left
                    anchors.right: parent.right
                    spacing: 0

                    ShellButton {
                        objectName: "onboardingAddComputer"
                        Layout.fillWidth: true
                        implicitHeight: 52
                        subtle: true
                        iconName: "link"
                        text: qsTr("Add a computer")
                        enabled: !(wizard.onboarding && wizard.onboarding.pairing)
                        onClicked: wizard.pairingOpen = !wizard.pairingOpen
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.margins: 12
                        Layout.topMargin: 0
                        visible: wizard.pairingOpen
                        spacing: 8

                        Label {
                            text: qsTr("Pairing link")
                            font.pixelSize: 13
                            font.weight: Font.Medium
                            color: wizard.foreground
                        }
                        ShellTextField {
                            id: pairingUrl

                            objectName: "onboardingPairingUrl"
                            Layout.fillWidth: true
                            placeholderText: "https://your-server:5230/pair#token=…"
                            readOnly: !!(wizard.onboarding && wizard.onboarding.pairing)
                            inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText | Qt.ImhUrlCharactersOnly
                            onAccepted: pairButton.clicked()
                        }
                        Label {
                            objectName: "onboardingPairingError"
                            Layout.fillWidth: true
                            visible: text.length > 0
                            wrapMode: Text.Wrap
                            text: wizard.onboarding ? (wizard.onboarding.pairingDetail || wizard.onboarding.pairingError || "") : ""
                            font.pixelSize: 13
                            color: Theme.palette.color("error", "#ef4444")
                        }
                        RowLayout {
                            Layout.fillWidth: true

                            ShellButton {
                                subtle: true
                                iconName: wizard.pairingHelpOpen ? "chevron-down" : "chevron-right"
                                text: qsTr("Need a pairing link?")
                                tint: wizard.muted
                                onClicked: wizard.pairingHelpOpen = !wizard.pairingHelpOpen
                            }
                            Item {
                                Layout.fillWidth: true
                            }
                            ShellButton {
                                id: pairButton

                                objectName: "onboardingPair"
                                primary: true
                                enabled: !(wizard.onboarding && wizard.onboarding.pairing) && pairingUrl.text.trim().length > 0
                                text: wizard.onboarding && wizard.onboarding.pairing ? qsTr("Pairing...") : qsTr("Pair")
                                onClicked: wizard.dispatch("onboarding.pair", { pairingUrl: pairingUrl.text.trim() })
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: wizard.pairingHelpOpen
                            spacing: 6

                            Detail {
                                text: qsTr("Run this on the computer with your code.")
                            }
                            TextEdit {
                                Layout.fillWidth: true
                                readOnly: true
                                selectByMouse: true
                                text: "npx hal-c2 pair"
                                font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
                                font.pixelSize: 12
                                color: wizard.foreground
                            }
                            Detail {
                                font.pixelSize: 11
                                textFormat: Text.StyledText
                                text: qsTr("Start HAL-C2 first, or run <tt>npx hal-c2 serve</tt>. Add <tt>--tailscale</tt> to use your tailnet.")
                            }
                        }
                    }
                }
            }

            ShellButton {
                objectName: "onboardingContinue"
                Layout.alignment: Qt.AlignRight
                Layout.topMargin: 24
                primary: true
                text: qsTr("Continue")
                enabled: !!(wizard.onboarding && wizard.onboarding.canContinue)
                onClicked: wizard.dispatch("onboarding.continue")
            }
        }
    }

    // ── Agents ───────────────────────────────────────────────
    Component {
        id: agentsStep

        ColumnLayout {
            spacing: 0

            Title {
                text: qsTr("Your agents")
            }
            Detail {
                Layout.topMargin: 10
                text: qsTr("Agents available on your selected computers.")
            }

            Repeater {
                model: wizard.onboarding ? wizard.onboarding.agents : []

                delegate: ColumnLayout {
                    id: section

                    required property var modelData

                    Layout.fillWidth: true
                    Layout.topMargin: 20
                    spacing: 6

                    Label {
                        text: section.modelData.label
                        font.pixelSize: 13
                        font.weight: Font.Medium
                        color: wizard.foreground
                    }

                    Repeater {
                        model: section.modelData.cards

                        delegate: Row {
                            id: agent

                            required property var modelData

                            objectName: "onboardingAgent_" + section.modelData.label + "_" + modelData.name
                            implicitHeight: agentRow.implicitHeight + 20

                            RowLayout {
                                id: agentRow

                                anchors.fill: parent
                                anchors.margins: 10
                                spacing: 12

                                ProviderIcon {
                                    driverKind: agent.modelData.driver
                                    size: 20
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2
                                    Label {
                                        text: agent.modelData.name
                                        font.pixelSize: 13
                                        font.weight: Font.Medium
                                        color: wizard.foreground
                                    }
                                    Label {
                                        Layout.fillWidth: true
                                        wrapMode: Text.Wrap
                                        text: agent.modelData.headline + (agent.modelData.detail ? " · " + agent.modelData.detail : "")
                                        font.pixelSize: 11
                                        color: wizard.muted
                                    }
                                }
                                Label {
                                    objectName: "onboardingAgentStatus"
                                    visible: agent.modelData.state !== "install" && agent.modelData.state !== "signIn"
                                    text: agent.modelData.state === "ready" ? qsTr("Ready")
                                        : agent.modelData.state === "checking" ? qsTr("Checking...")
                                        : agent.modelData.state === "disabled" ? qsTr("Disabled")
                                        : agent.modelData.headline
                                    font.pixelSize: 11
                                    font.weight: agent.modelData.state === "ready" ? Font.Medium : Font.Normal
                                    color: agent.modelData.state === "ready" ? Theme.palette.color("success", "#22c55e") : wizard.muted
                                }
                                ShellButton {
                                    objectName: "onboardingAgentAction"
                                    visible: agent.modelData.state === "install" || agent.modelData.state === "signIn"
                                    subtle: true
                                    iconName: "terminal"
                                    text: agent.modelData.state === "signIn" ? qsTr("Sign in") : qsTr("Install")
                                    enabled: !agent.modelData.terminalOpen && agent.modelData.terminalAvailable
                                    onClicked: wizard.dispatch("onboarding.agent", {
                                        environmentId: section.modelData.environmentId,
                                        driver: agent.modelData.driver
                                    })
                                }
                            }
                        }
                    }

                    // AgentInstallTerminal.
                    Row {
                        id: setupRow

                        readonly property var terminal: wizard.onboarding ? wizard.onboarding.terminal : null
                        readonly property string status: terminal ? terminal.status : ""

                        objectName: "onboardingSetup"
                        Layout.topMargin: 10
                        visible: !!terminal && terminal.environmentId === section.modelData.environmentId
                        implicitHeight: setup.implicitHeight
                        clip: true

                        ColumnLayout {
                            id: setup

                            anchors.left: parent.left
                            anchors.right: parent.right
                            spacing: 0

                            RowLayout {
                                Layout.fillWidth: true
                                Layout.leftMargin: 12
                                Layout.rightMargin: 6
                                Layout.topMargin: 4
                                Layout.bottomMargin: 4

                                Label {
                                    objectName: "onboardingSetupStatus"
                                    readonly property string status: setupRow.status

                                    Layout.fillWidth: true
                                    wrapMode: Text.Wrap
                                    text: status === "ready" ? qsTr("Review the command, then press Enter to run it.")
                                        : status === "openFailed" ? qsTr("Could not open the setup terminal.")
                                        : qsTr("Preparing command...")
                                    font.pixelSize: 11
                                    font.weight: Font.Medium
                                    color: wizard.muted
                                }
                                ShellButton {
                                    objectName: "onboardingSetupRetry"
                                    visible: setupRow.status === "openFailed"
                                    subtle: true
                                    implicitHeight: 22
                                    text: qsTr("Retry")
                                    onClicked: wizard.dispatch("onboarding.terminal.retry")
                                }
                                ShellButton {
                                    objectName: "onboardingSetupClose"
                                    subtle: true
                                    implicitHeight: 22
                                    text: qsTr("Close")
                                    onClicked: wizard.dispatch("onboarding.terminal.close")
                                }
                            }
                            Loader {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 256
                                active: setupRow.visible && setupRow.status === "ready"
                                source: active ? "OnboardingTerminal.qml" : ""
                            }
                        }
                    }
                }
            }

            ShellButton {
                objectName: "onboardingContinue"
                Layout.alignment: Qt.AlignRight
                Layout.topMargin: 24
                primary: true
                text: qsTr("Continue")
                onClicked: wizard.dispatch("onboarding.continue")
            }
        }
    }

    // ── Projects ─────────────────────────────────────────────
    component Meta: RowLayout {
        property var item: ({})
        property bool icons: true

        spacing: 8
        ProviderIcon {
            visible: parent.icons
            opacity: parent.item.claude ? 1 : 0
            driverKind: "claudeAgent"
            size: 12
        }
        ProviderIcon {
            visible: parent.icons
            opacity: parent.item.codex ? 1 : 0
            driverKind: "codex"
            size: 12
        }
        Label {
            Layout.preferredWidth: 28
            horizontalAlignment: Text.AlignRight
            text: parent.item.threadCount ?? 0
            font.pixelSize: 11
            color: wizard.muted
        }
        Label {
            Layout.preferredWidth: 28
            horizontalAlignment: Text.AlignRight
            text: parent.item.age ?? ""
            font.pixelSize: 11
            color: wizard.muted
        }
    }

    component CandidateRow: RowLayout {
        id: candidateRow

        property var item: ({})
        property string label: ""
        property string secondary: ""
        property bool nested: false

        Layout.fillWidth: true
        Layout.leftMargin: nested ? 24 : 0
        spacing: 10

        CheckBox {
            objectName: "onboardingProjectCheck"
            checked: !!candidateRow.item.checked
            enabled: !wizard.importing
            Accessible.name: candidateRow.item.path ?? ""
            onToggled: wizard.dispatch("onboarding.project", { keys: [candidateRow.item.key], selected: checked })
        }
        Label {
            Layout.fillWidth: true
            elide: Text.ElideMiddle
            text: candidateRow.label
            font.family: candidateRow.nested ? (Theme.fontMono.length > 0 ? Theme.fontMono : "monospace") : font.family
            font.pixelSize: candidateRow.nested ? 11 : 13
            font.weight: candidateRow.nested ? Font.Normal : Font.Medium
            color: wizard.foreground
            ToolTip.visible: hover.hovered
            ToolTip.text: candidateRow.item.path ?? ""

            HoverHandler {
                id: hover
            }
        }
        Label {
            visible: candidateRow.secondary.length > 0
            Layout.maximumWidth: 160
            elide: Text.ElideMiddle
            text: candidateRow.secondary
            font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
            font.pixelSize: 11
            color: wizard.muted
        }
        Meta {
            item: candidateRow.item
            icons: !candidateRow.nested
        }
    }

    Component {
        id: importStep

        ColumnLayout {
            spacing: 0

            // Nothing found yet.
            ColumnLayout {
                Layout.fillWidth: true
                visible: !!wizard.importState.loading
                spacing: 12

                Title {
                    text: qsTr("Your projects")
                }
                BusyIndicator {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: 24
                    running: parent.visible
                }
                Detail {
                    Layout.bottomMargin: 24
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("Looking for projects from Claude Code and Codex…")
                }
                ShellButton {
                    Layout.alignment: Qt.AlignRight
                    subtle: true
                    text: qsTr("Do not import projects")
                    onClicked: wizard.dispatch("onboarding.skip")
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                visible: !wizard.importState.loading
                spacing: 0

                Title {
                    text: qsTr("Choose your projects")
                }
                Detail {
                    Layout.topMargin: 10
                    text: qsTr("Import projects and conversations from your selected computers.")
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 20
                    visible: (wizard.importState.total ?? 0) > 0

                    Label {
                        objectName: "onboardingSelectedCount"
                        Layout.fillWidth: true
                        text: qsTr("%1 of %2 selected").arg(wizard.importState.selectedCount ?? 0).arg(wizard.importState.total ?? 0)
                        font.pixelSize: 11
                        color: wizard.muted
                    }
                    ShellButton {
                        objectName: "onboardingSelectAll"
                        subtle: true
                        implicitHeight: 22
                        text: qsTr("Select all")
                        enabled: !wizard.importing && wizard.importState.selectedCount !== wizard.importState.total
                        onClicked: wizard.dispatch("onboarding.selectAll")
                    }
                    ShellButton {
                        objectName: "onboardingSelectNone"
                        subtle: true
                        implicitHeight: 22
                        text: qsTr("Select none")
                        enabled: !wizard.importing && (wizard.importState.selectedCount ?? 0) > 0
                        onClicked: wizard.dispatch("onboarding.selectNone")
                    }
                }

                Repeater {
                    model: wizard.importState.scans ?? []

                    delegate: ColumnLayout {
                        id: scan

                        required property var modelData

                        Layout.fillWidth: true
                        Layout.topMargin: 12
                        spacing: 4

                        Label {
                            visible: !!wizard.importState.multiple
                            text: scan.modelData.label
                            font.pixelSize: 13
                            font.weight: Font.Medium
                            color: wizard.foreground
                        }
                        RowLayout {
                            visible: scan.modelData.pending
                            spacing: 8
                            BusyIndicator {
                                implicitWidth: 16
                                implicitHeight: 16
                                running: parent.visible
                            }
                            Detail {
                                text: qsTr("Looking for projects…")
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            visible: !scan.modelData.pending && scan.modelData.error.length > 0
                            Detail {
                                objectName: "onboardingScanError"
                                text: qsTr("Could not check projects. %1").arg(scan.modelData.error)
                            }
                            ShellButton {
                                subtle: true
                                text: qsTr("Retry")
                                onClicked: wizard.dispatch("onboarding.scan.retry", { environmentId: scan.modelData.environmentId })
                            }
                        }
                        Detail {
                            visible: scan.modelData.empty
                            text: qsTr("No existing Claude Code or Codex projects found.")
                        }
                        Detail {
                            objectName: "onboardingScanLimit"
                            visible: scan.modelData.truncated
                            font.pixelSize: 11
                            text: qsTr("Scan limit reached. Some projects or conversations may be missing.")
                        }

                        Repeater {
                            model: scan.modelData.repositories

                            delegate: ColumnLayout {
                                id: group

                                required property var modelData
                                property bool open: true

                                Layout.fillWidth: true
                                spacing: 2

                                CandidateRow {
                                    visible: group.modelData.single
                                    item: group.modelData.candidates[0]
                                    label: group.modelData.label
                                    secondary: group.modelData.secondary
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    visible: !group.modelData.single
                                    spacing: 10

                                    CheckBox {
                                        objectName: "onboardingGroupCheck"
                                        tristate: group.modelData.partial
                                        checkState: group.modelData.checked ? Qt.Checked : group.modelData.partial ? Qt.PartiallyChecked : Qt.Unchecked
                                        enabled: !wizard.importing
                                        Accessible.name: group.modelData.label
                                        nextCheckState: () => group.modelData.checked ? Qt.Unchecked : Qt.Checked
                                        onToggled: wizard.dispatch("onboarding.project", {
                                            keys: group.modelData.candidates.map(candidate => candidate.key),
                                            selected: !group.modelData.checked
                                        })
                                    }
                                    ShellButton {
                                        Layout.fillWidth: true
                                        subtle: true
                                        iconName: group.open ? "chevron-down" : "chevron-right"
                                        text: group.modelData.label
                                        onClicked: group.open = !group.open
                                    }
                                    Meta {
                                        item: group.modelData
                                    }
                                }
                                Repeater {
                                    model: !group.modelData.single && group.open ? group.modelData.candidates : []

                                    delegate: CandidateRow {
                                        required property var modelData

                                        item: modelData
                                        label: modelData.path
                                        nested: true
                                    }
                                }
                            }
                        }

                        // Other folders, collapsed.
                        ColumnLayout {
                            id: other

                            property bool open: false

                            Layout.fillWidth: true
                            visible: scan.modelData.other.count > 0
                            spacing: 2

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10

                                CheckBox {
                                    objectName: "onboardingOtherCheck"
                                    tristate: scan.modelData.other.partial
                                    checkState: scan.modelData.other.checked ? Qt.Checked : scan.modelData.other.partial ? Qt.PartiallyChecked : Qt.Unchecked
                                    enabled: !wizard.importing
                                    Accessible.name: qsTr("Other folders")
                                    nextCheckState: () => scan.modelData.other.checked ? Qt.Unchecked : Qt.Checked
                                    onToggled: wizard.dispatch("onboarding.project", {
                                        keys: scan.modelData.other.candidates.map(candidate => candidate.key),
                                        selected: !scan.modelData.other.checked
                                    })
                                }
                                ShellButton {
                                    Layout.fillWidth: true
                                    subtle: true
                                    iconName: other.open ? "chevron-down" : "chevron-right"
                                    text: qsTr("Other folders")
                                    tint: wizard.muted
                                    onClicked: other.open = !other.open
                                }
                                Label {
                                    text: scan.modelData.other.count === 1 ? qsTr("1 folder") : qsTr("%1 folders").arg(scan.modelData.other.count)
                                    font.pixelSize: 11
                                    color: wizard.muted
                                }
                            }
                            Repeater {
                                model: other.open ? scan.modelData.other.candidates : []

                                delegate: CandidateRow {
                                    required property var modelData

                                    item: modelData
                                    label: modelData.path
                                    nested: true
                                }
                            }
                        }
                    }
                }

                Label {
                    objectName: "onboardingImportError"
                    Layout.fillWidth: true
                    Layout.topMargin: 12
                    visible: text.length > 0
                    wrapMode: Text.Wrap
                    text: wizard.importState.error ?? ""
                    font.pixelSize: 13
                    color: Theme.palette.color("error", "#ef4444")
                }

                RowLayout {
                    Layout.alignment: Qt.AlignRight
                    Layout.topMargin: 24
                    spacing: 12

                    ShellButton {
                        objectName: "onboardingSkip"
                        subtle: true
                        enabled: !wizard.importing
                        text: (wizard.importState.error ?? "").length > 0 ? qsTr("Continue without the rest") : qsTr("Do not import projects")
                        onClicked: wizard.dispatch("onboarding.skip")
                    }
                    ShellButton {
                        objectName: "onboardingImport"
                        primary: true
                        enabled: !wizard.importing && (wizard.importState.selectedCount ?? 0) > 0
                        text: wizard.importing ? qsTr("Importing…")
                            : (wizard.importState.selectedCount === 1 ? qsTr("Import 1 project") : qsTr("Import %1 projects").arg(wizard.importState.selectedCount ?? 0))
                        onClicked: wizard.dispatch("onboarding.import")
                    }
                }
            }
        }
    }
}
