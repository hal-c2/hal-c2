pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Layouts
import HalC2.Shell

// Settings → SnapShots, natively (SnapShotController's `snapShot`): turning
// capture on, the setup walk-through, the shortcut recorder and the capture
// cues. Every string comes from the controller; this page only lays it out
// and sends what the user does.
SettingsPage {
    id: snap
    readonly property var config: Shell.state.snapShot?.config ?? null

    readonly property var settings: Shell.state.snapShot ?? null
    readonly property var shortcut: settings?.shortcut ?? null
    readonly property var wizard: settings?.wizard ?? null
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property bool mac: Qt.platform.os === "osx"

    objectName: "snapShotSettings"
    title: qsTr("SnapShots")

    // A row's title, what it does, and why it cannot, beside its control.
    component Row: RowLayout {
        id: row

        property string heading: ""
        property string description: ""
        property string status: ""
        default property alias control: slot.data

        Layout.fillWidth: true
        spacing: 12

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Label {
                text: row.heading
                color: Theme.palette.color("text", "#e4e4e7")
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.Medium
            }

            Label {
                Layout.fillWidth: true
                visible: text.length > 0
                text: row.description
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            Label {
                objectName: "status"
                Layout.fillWidth: true
                visible: text.length > 0
                text: row.status
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }
        }

        RowLayout {
            id: slot
            spacing: 6
        }
    }

    // A cue or option that is a switch: accessibility, flash, animations.
    component Toggle: Row {
        id: toggle

        property string key: ""
        property var model: null

        status: model?.status ?? ""
        objectName: "snapShot:" + key

        ShellSwitch {
            objectName: "control"
            enabled: toggle.model?.enabled ?? false
            checked: toggle.model?.checked ?? false
            Accessible.name: toggle.heading
            onToggled: {
                Shell.dispatch("snapShot.set", { key: toggle.key, value: checked });
                // A refusal leaves the state as it was, so nothing would move the switch back.
                checked = Qt.binding(() => toggle.model?.checked ?? false);
            }
        }
    }

    // Records a shortcut: every key goes to the controller while it listens.
    component Recorder: ShellButton {
        id: recorder

        // Inline components cannot reach the page's id, so the recorder reads the state itself.
        readonly property var shortcut: Shell.state.snapShot?.shortcut ?? null
        readonly property bool mac: Qt.platform.os === "osx"

        objectName: "recorder"
        text: recorder.shortcut?.keys ?? ""
        focusPolicy: Qt.StrongFocus
        onClicked: {
            // A shortcut in the compositor's config is changed through setup's review.
            if ((recorder.shortcut?.managed ?? false) && !Shell.state.snapShot?.wizard) {
                Shell.dispatch("snapShot.setup.open", { step: "shortcut" });
                return;
            }
            forceActiveFocus();
            Shell.dispatch("snapShot.record.start");
        }
        onActiveFocusChanged: if (!activeFocus && (recorder.shortcut?.recording ?? false)) Shell.dispatch("snapShot.record.cancel")

        function modifier(key) {
            switch (key) {
            case Qt.Key_Shift: return "shift";
            case Qt.Key_Control: return recorder.mac ? "meta" : "control";
            case Qt.Key_Meta: return recorder.mac ? "control" : "meta";
            case Qt.Key_Alt: return "alt";
            }
            return "";
        }

        // A plain Tab moves focus on (the controller ignores it too).
        function plainTab(event) {
            return (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)
                && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier));
        }

        Keys.onShortcutOverride: event => event.accepted = (recorder.shortcut?.recording ?? false) && !recorder.plainTab(event)
        Keys.onPressed: event => {
            if (!(recorder.shortcut?.recording ?? false) || recorder.plainTab(event))
                return;
            event.accepted = true;
            const held = modifier(event.key);
            if (held.length > 0) {
                if (!event.isAutoRepeat)
                    Shell.dispatch("snapShot.record.modifier", { modifier: held, code: event.nativeScanCode, down: true });
            } else {
                Shell.dispatch("snapShot.record.key", { key: event.key, modifiers: event.modifiers, repeat: event.isAutoRepeat });
            }
        }
        Keys.onReleased: event => {
            const held = modifier(event.key);
            if (held.length > 0 && (recorder.shortcut?.recording ?? false))
                Shell.dispatch("snapShot.record.modifier", { modifier: held, code: event.nativeScanCode, down: false });
        }
    }

    Row {
        objectName: "snapShot:enabled"
        heading: qsTr("SnapShots")
        description: snap.settings?.description ?? ""
        status: snap.settings?.status ?? ""

        ShellButton {
            objectName: "setup"
            visible: (snap.settings?.setupLabel ?? "").length > 0 && snap.wizard === null
            subtle: true
            text: snap.settings?.setupLabel ?? ""
            onClicked: Shell.dispatch("snapShot.setup.open", { step: "resume" })
        }

        ShellSwitch {
            objectName: "control"
            enabled: (snap.settings?.ready ?? false) && (snap.settings?.available ?? false)
            checked: snap.settings?.switchOn ?? false
            Accessible.name: qsTr("SnapShots")
            onToggled: Shell.dispatch("snapShot.enable", { on: checked })
        }
    }

    // The setup walk-through: allow capture, then choose a shortcut.
    Rectangle {
        objectName: "snapShotSetup"
        Layout.fillWidth: true
        visible: snap.wizard !== null
        // Nothing is left or stepped through while the desktop answers.
        enabled: !(snap.wizard?.busy ?? false)
        implicitHeight: setup.implicitHeight + 32
        radius: Math.min(Theme.radius, 10)
        color: Theme.palette.color("surface", "#18181b")
        border.color: Theme.palette.color("border", "#27272a")

        ColumnLayout {
            id: setup

            x: 16
            y: 16
            width: parent.width - 32
            spacing: 10

            Label {
                text: snap.wizard?.title ?? ""
                color: Theme.palette.color("text", "#e4e4e7")
                font.pixelSize: Math.round(14 * Theme.fontScale)
                font.weight: Font.DemiBold
            }

            RowLayout {
                spacing: 12

                Repeater {
                    model: [{ step: "access", label: qsTr("Access") }, { step: "shortcut", label: qsTr("Shortcut") }]

                    delegate: Label {
                        required property var modelData
                        text: modelData.label
                        color: snap.wizard?.step === modelData.step ? Theme.palette.color("text", "#e4e4e7") : snap.muted
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        font.weight: snap.wizard?.step === modelData.step ? Font.DemiBold : Font.Normal
                    }
                }
            }

            Label {
                objectName: "heading"
                text: snap.wizard?.heading ?? ""
                color: Theme.palette.color("text", "#e4e4e7")
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.Medium
            }

            Label {
                Layout.fillWidth: true
                text: snap.wizard?.body ?? ""
                color: snap.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            // macOS grants each permission on its own.
            Repeater {
                model: snap.wizard?.step === "access" ? (snap.wizard?.permissionRows ?? []) : []

                RowLayout {
                    required property var modelData

                    objectName: "permission:" + modelData.id
                    Layout.fillWidth: true
                    spacing: 8

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2

                        Label {
                            text: modelData.title
                            color: Theme.palette.color("text", "#e4e4e7")
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            font.weight: Font.Medium
                        }

                        Label {
                            Layout.fillWidth: true
                            text: modelData.description
                            color: snap.muted
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            wrapMode: Text.Wrap
                        }
                    }

                    Label {
                        objectName: "allowed"
                        visible: modelData.granted
                        text: qsTr("Allowed")
                        color: snap.muted
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }

                    ShellButton {
                        objectName: "allow"
                        visible: !modelData.granted
                        enabled: !(snap.wizard?.permissionsBusy ?? false)
                        text: qsTr("Allow")
                        onClicked: Shell.dispatch("snapShot.permission.allow", { id: modelData.id })
                    }
                }
            }

            Label {
                objectName: "permissionsError"
                Layout.fillWidth: true
                visible: text.length > 0
                text: snap.wizard?.permissionsError ?? ""
                color: snap.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            Label {
                objectName: "checkMessage"
                Layout.fillWidth: true
                visible: text.length > 0
                text: snap.wizard?.checkMessage ?? ""
                color: snap.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            // Advanced: undoing what setup did, and the like.
            Repeater {
                model: snap.wizard?.step === "access" ? (snap.wizard?.advanced ?? []) : []

                delegate: ColumnLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 2

                    ShellButton {
                        objectName: "advanced-" + parent.modelData.action
                        text: parent.modelData.label
                        onClicked: Shell.dispatch("snapShot.setup.action", { action: parent.modelData.action })
                    }

                    Label {
                        Layout.fillWidth: true
                        visible: text.length > 0
                        text: parent.modelData.note ?? ""
                        color: snap.muted
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        wrapMode: Text.Wrap
                    }
                }
            }

            Label {
                Layout.fillWidth: true
                visible: text.length > 0
                text: snap.wizard?.details ?? ""
                color: Theme.palette.color("warning", "#fbbf24")
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            RowLayout {
                visible: snap.wizard?.step === "shortcut"
                spacing: 8

                Recorder {}

                ShellButton {
                    objectName: "permissions"
                    visible: snap.wizard?.permissions ?? false
                    subtle: true
                    text: snap.wizard?.permissionsLabel ?? ""
                    onClicked: Shell.dispatch("snapShot.shortcut.permissions")
                }
            }

            Label {
                Layout.fillWidth: true
                visible: snap.wizard?.step === "shortcut" && text.length > 0
                text: snap.wizard?.attention || (snap.shortcut?.status ?? "")
                color: snap.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            // The shortcut kept in the compositor's config: review, then save.
            ColumnLayout {
                id: configPanel

                readonly property var config: snap.config
                readonly property var review: config?.review ?? null
                property bool advanced: false
                readonly property bool failed: (config?.error ?? "").length > 0

                Layout.fillWidth: true
                visible: snap.wizard?.step === "shortcut" && config !== null
                spacing: 8
                onFailedChanged: if (failed) advanced = true

                Label {
                    objectName: "configIntro"
                    Layout.fillWidth: true
                    text: configPanel.config?.intro ?? ""
                    color: snap.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    wrapMode: Text.Wrap
                }

                Label {
                    objectName: "configConnecting"
                    Layout.fillWidth: true
                    visible: text.length > 0
                    text: configPanel.config?.connecting ?? ""
                    color: snap.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    wrapMode: Text.Wrap
                }

                Label {
                    objectName: "configError"
                    Layout.fillWidth: true
                    visible: text.length > 0
                    text: configPanel.config?.error ?? ""
                    color: Theme.palette.color("warning", "#fbbf24")
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    wrapMode: Text.Wrap
                }

                ShellButton {
                    objectName: "configReview"
                    visible: configPanel.review === null
                    enabled: configPanel.config?.canReview ?? false
                    text: configPanel.config?.reviewLabel ?? ""
                    onClicked: Shell.dispatch("snapShot.config.review")
                }

                Label {
                    objectName: "configNote"
                    Layout.fillWidth: true
                    visible: text.length > 0
                    text: configPanel.review?.note ?? ""
                    color: snap.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    wrapMode: Text.Wrap
                }

                Column {
                    Layout.fillWidth: true
                    visible: configPanel.review?.changed ?? false

                    Repeater {
                        objectName: "configDiff"
                        model: configPanel.review?.lines ?? []

                        delegate: Label {
                            required property var modelData
                            width: parent.width
                            text: (modelData.kind === "added" ? "+ " : modelData.kind === "removed" ? "- " : "  ") + modelData.text
                            color: modelData.kind === "added" ? Theme.palette.color("success", "#34d399")
                                 : modelData.kind === "removed" ? Theme.palette.color("destructive", "#f87171") : snap.muted
                            font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            wrapMode: Text.WrapAnywhere
                        }
                    }
                }

                RowLayout {
                    visible: configPanel.review?.changed ?? false
                    spacing: 8

                    ShellButton {
                        objectName: "configSave"
                        primary: true
                        enabled: configPanel.review?.canSave ?? false
                        text: configPanel.review?.saveLabel ?? ""
                        onClicked: Shell.dispatch("snapShot.config.save", { id: configPanel.review?.id ?? "" })
                    }

                    ShellButton {
                        objectName: "configCancel"
                        subtle: true
                        text: qsTr("Cancel")
                        onClicked: Shell.dispatch("snapShot.config.cancel")
                    }
                }

                ShellButton {
                    objectName: "configAdvanced"
                    subtle: true
                    text: qsTr("Advanced")
                    onClicked: configPanel.advanced = !configPanel.advanced
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    visible: configPanel.advanced
                    spacing: 8

                    Label {
                        objectName: "configDetails"
                        Layout.fillWidth: true
                        visible: text.length > 0
                        text: configPanel.config?.details ?? ""
                        color: Theme.palette.color("warning", "#fbbf24")
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        wrapMode: Text.Wrap
                    }

                    Repeater {
                        // What the user may need to read, in the order they would need it.
                        model: [
                            { name: "configFile", text: configPanel.config?.file ?? "" },
                            { name: "configLinked", text: configPanel.review?.linked ?? "" },
                            { name: "configFileHint", text: configPanel.config?.fileHint ?? "" },
                            { name: "configBackup", text: configPanel.config?.backup ?? "" }
                        ]

                        delegate: Label {
                            required property var modelData
                            objectName: modelData.name
                            Layout.fillWidth: true
                            visible: text.length > 0
                            text: modelData.text
                            color: snap.muted
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            wrapMode: Text.WrapAnywhere
                        }
                    }

                    RowLayout {
                        spacing: 8

                        ShellButton {
                            objectName: "configChooseFile"
                            subtle: true
                            enabled: configPanel.config?.canReview ?? false
                            text: qsTr("Choose file…")
                            onClicked: configFileDialog.open()
                        }

                        ShellButton {
                            objectName: "configRemove"
                            subtle: true
                            enabled: configPanel.config?.canReview ?? false
                            text: qsTr("Remove shortcut…")
                            onClicked: Shell.dispatch("snapShot.config.review", { remove: true })
                        }
                    }

                    Label {
                        objectName: "configManual"
                        Layout.fillWidth: true
                        text: configPanel.config?.manual ?? ""
                        color: snap.muted
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        wrapMode: Text.Wrap
                    }

                    Label {
                        objectName: "configBinding"
                        Layout.fillWidth: true
                        text: configPanel.config?.binding ?? ""
                        color: snap.muted
                        font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        wrapMode: Text.WrapAnywhere
                    }

                    RowLayout {
                        spacing: 8

                        ShellButton {
                            objectName: "configCopy"
                            subtle: true
                            text: configPanel.config?.copyLabel ?? ""
                            onClicked: Shell.dispatch("snapShot.config.copy")
                        }

                        ShellButton {
                            objectName: "configComplete"
                            subtle: true
                            text: qsTr("I've added the shortcut")
                            onClicked: Shell.dispatch("snapShot.config.complete")
                        }
                    }

                    Label {
                        objectName: "configRemoveNote"
                        Layout.fillWidth: true
                        text: configPanel.config?.removeNote ?? ""
                        color: snap.muted
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        wrapMode: Text.Wrap
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                ShellButton {
                    objectName: "back"
                    visible: snap.wizard?.step === "shortcut"
                    subtle: true
                    text: qsTr("Back")
                    onClicked: Shell.dispatch("snapShot.setup.back")
                }

                Item { Layout.fillWidth: true }

                ShellButton {
                    objectName: "close"
                    subtle: true
                    text: snap.wizard?.closeLabel ?? ""
                    onClicked: Shell.dispatch("snapShot.setup.close", { completed: false })
                }

                ShellButton {
                    objectName: "continue"
                    visible: snap.wizard?.step === "access"
                    primary: true
                    enabled: snap.wizard?.continueEnabled ?? true
                    text: snap.wizard?.continueLabel ?? ""
                    onClicked: snap.wizard?.action
                               ? Shell.dispatch("snapShot.setup.action", { action: snap.wizard.action })
                               : Shell.dispatch("snapShot.setup.continue")
                }

                ShellButton {
                    objectName: "done"
                    visible: snap.wizard?.step === "shortcut"
                    primary: true
                    enabled: snap.wizard?.doneEnabled ?? false
                    text: snap.wizard?.doneLabel ?? ""
                    onClicked: Shell.dispatch("snapShot.setup.done")
                }
            }
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        visible: (snap.settings?.rows ?? false) && snap.wizard === null
        spacing: 14

        Row {
            objectName: "snapShot:shortcut"
            heading: qsTr("Shortcut")
            description: snap.shortcut?.description ?? ""
            status: snap.shortcut?.status ?? ""

            Recorder {}

            ShellButton {
                objectName: "save"
                visible: snap.shortcut?.changed ?? false
                primary: true
                enabled: snap.shortcut?.canSave ?? false
                text: qsTr("Save")
                onClicked: Shell.dispatch("snapShot.shortcut.save")
            }

            ShellButton {
                objectName: "discard"
                visible: snap.shortcut?.changed ?? false
                subtle: true
                text: qsTr("Cancel")
                onClicked: Shell.dispatch("snapShot.shortcut.discard")
            }

            ShellButton {
                objectName: "permissions"
                visible: snap.shortcut?.permissions ?? false
                enabled: snap.shortcut?.permissionsEnabled ?? false
                subtle: true
                text: qsTr("Shortcut permissions")
                onClicked: Shell.dispatch("snapShot.shortcut.permissions")
            }
        }

        Toggle {
            key: "accessibility"
            model: snap.settings?.accessibility ?? null
            heading: qsTr("Include app text")
            description: qsTr("Include text and controls when the app makes them available.")
        }

        Row {
            objectName: "snapShot:sound"
            heading: qsTr("Sound")
            description: qsTr("Choose the sound played when capture starts.")

            ShellComboBox {
                id: soundChoices
                objectName: "control"
                outline: true
                implicitWidth: 170
                readonly property var sounds: snap.settings?.sound?.choices ?? []
                model: sounds.map(choice => choice.label)
                currentIndex: sounds.findIndex(choice => choice.value === (snap.settings?.sound?.value ?? "soft-pop"))
                Accessible.name: qsTr("Sound")
                onActivated: index => Shell.dispatch("snapShot.sound", { value: sounds[index].value })
                // Right arrow hears the highlighted sound, as its row's button does.
                Keys.onRightPressed: event => {
                    const choice = popup.visible ? sounds[highlightedIndex] : null;
                    event.accepted = !!choice;
                    if (choice && choice.value !== "off")
                        Shell.dispatch("snapShot.sound.play", { sound: choice.value });
                }
                // Hears a sound without choosing it; the choices stay open.
                rowAction: ShellButton {
                    readonly property var choice: soundChoices.sounds[parent?.row ?? 0] ?? null
                    objectName: "play:" + (choice?.value ?? "")
                    visible: (choice?.value ?? "off") !== "off"
                    implicitWidth: 22
                    implicitHeight: 22
                    subtle: true
                    iconName: "play"
                    Accessible.name: qsTr("Play %1").arg(choice?.label ?? "")
                    onClicked: Shell.dispatch("snapShot.sound.play", { sound: choice.value })
                }
            }
        }

        Toggle {
            key: "flash"
            model: snap.settings?.flash ?? null
            heading: qsTr("Flash")
            description: qsTr("Show a gentle cue on the captured window.")
        }

        Toggle {
            key: "animations"
            model: snap.settings?.animations ?? null
            heading: qsTr("Animations")
            description: qsTr("Animate captured windows into your draft.")
        }
    }

    FileDialog {
        id: configFileDialog

        title: qsTr("Choose your config file")
        fileMode: FileDialog.OpenFile
        onAccepted: Shell.dispatch("snapShot.config.review", { file: selectedFile.toString().replace(/^file:\/\//, "") })
    }
}
