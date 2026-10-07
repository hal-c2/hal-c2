pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → SnapShots, natively (SnapShotController's `snapShot`): turning
// capture on, the setup walk-through, the shortcut recorder and the capture
// cues. Every string comes from the controller; this page only lays it out
// and sends what the user does.
SettingsPage {
    id: snap

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

        Switch {
            objectName: "control"
            enabled: toggle.model?.enabled ?? false
            checked: toggle.model?.checked ?? false
            Accessible.name: toggle.heading
            onToggled: Shell.dispatch("snapShot.set", { key: toggle.key, value: checked })
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

        Keys.onShortcutOverride: event => event.accepted = (recorder.shortcut?.recording ?? false) && event.key !== Qt.Key_Tab
                                                          && event.key !== Qt.Key_Backtab
        Keys.onPressed: event => {
            if (!(recorder.shortcut?.recording ?? false) || event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)
                return;
            event.accepted = true;
            if (event.isAutoRepeat)
                return;
            const held = modifier(event.key);
            if (held.length > 0)
                Shell.dispatch("snapShot.record.modifier", { modifier: held, code: event.nativeScanCode, down: true });
            else
                Shell.dispatch("snapShot.record.key", { key: event.key, modifiers: event.modifiers });
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

        Switch {
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
                    text: snap.wizard?.continueLabel ?? ""
                    onClicked: Shell.dispatch("snapShot.setup.continue")
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

            ShellButton {
                objectName: "play"
                visible: (snap.settings?.sound?.value ?? "off") !== "off"
                subtle: true
                iconName: "play"
                Accessible.name: qsTr("Play %1").arg(snap.settings?.sound?.label ?? "")
                onClicked: Shell.dispatch("snapShot.sound.play", { sound: snap.settings?.sound?.value })
            }

            ShellComboBox {
                objectName: "control"
                outline: true
                implicitWidth: 170
                readonly property var sounds: ["off", "soft-pop", "camera-shutter"]
                model: [qsTr("Off"), qsTr("Whoosh (Default)"), qsTr("Click")]
                currentIndex: sounds.indexOf(snap.settings?.sound?.value ?? "soft-pop")
                Accessible.name: qsTr("Sound")
                onActivated: index => Shell.dispatch("snapShot.sound", { value: sounds[index] })
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
}
