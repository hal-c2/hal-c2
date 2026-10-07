pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → Storage, natively: the cleanup rules the MC sweeps by, across
// the settings scope (StorageSettingsController's `storageSettings`). A rule
// that differs between the selected environments shows as mixed until one
// value is chosen for all of them.
SettingsPage {
    id: storage

    readonly property var settings: Shell.state.storageSettings ?? null
    readonly property bool editable: Shell.state.settingsScope?.editable ?? false
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")

    objectName: "storageSettings"
    title: qsTr("Storage")

    component Rule: RowLayout {
        id: rule

        required property var modelData
        readonly property bool editable: Shell.state.settingsScope?.editable ?? false

        objectName: "storageRule:" + modelData.key
        Layout.fillWidth: true
        spacing: 12

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Label {
                text: rule.modelData.title
                color: Theme.palette.color("text", "#e4e4e7")
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.Medium
            }

            Label {
                objectName: "mixed"
                visible: rule.modelData.mixed
                text: qsTr("Mixed across selected machines")
                color: Theme.palette.color("warning", "#fbbf24")
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }

            Label {
                Layout.fillWidth: true
                text: rule.modelData.description
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }
        }

        SpinBox {
            objectName: "days"
            visible: rule.modelData.days && rule.modelData.value !== null && !rule.modelData.mixed
            enabled: rule.editable
            from: 1
            to: 3650
            editable: true
            value: rule.modelData.value ?? 8
            textFromValue: (number, locale) => qsTr("%1 days").arg(number)
            valueFromText: (text, locale) => parseInt(text) || value
            Accessible.name: qsTr("%1 in days").arg(rule.modelData.title)
            onValueModified: Shell.dispatch("storageSettings.set", { key: rule.modelData.key, value: value })
        }

        Label {
            visible: rule.modelData.days && rule.modelData.value === null && !rule.modelData.mixed
            text: qsTr("Off")
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        Switch {
            objectName: "control"
            enabled: rule.editable
            // A mixed rule is neither: choosing sets it everywhere.
            checked: !rule.modelData.mixed && (rule.modelData.days ? rule.modelData.value !== null : rule.modelData.value === true)
            Accessible.name: rule.modelData.title
            onToggled: Shell.dispatch("storageSettings.set", {
                key: rule.modelData.key,
                value: rule.modelData.days ? (checked ? 8 : null) : checked
            })
        }
    }

    SettingsScopeSentence {}

    ColumnLayout {
        objectName: "storageNotice"
        Layout.fillWidth: true
        visible: storage.settings?.status === "unsupported"
        spacing: 6

        Label {
            Layout.fillWidth: true
            text: storage.settings?.notice ?? ""
            color: Theme.palette.color("text", "#e4e4e7")
            font.pixelSize: Math.round(13 * Theme.fontScale)
            wrapMode: Text.Wrap
        }

        Flow {
            Layout.fillWidth: true
            spacing: 6

            Repeater {
                model: storage.settings?.eligible ?? []

                delegate: ShellButton {
                    required property var modelData
                    objectName: "eligible_" + modelData.id
                    subtle: true
                    text: modelData.label
                    onClicked: Shell.dispatch("settingsScope.environment", { id: modelData.id })
                }
            }
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        visible: storage.settings?.status === "ready"
        spacing: 12

        Label {
            text: qsTr("Worktrees")
            color: storage.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
            font.weight: Font.DemiBold
        }

        RowLayout {
            objectName: "storageMode"
            Layout.fillWidth: true
            visible: storage.settings?.projectScope ?? false
            spacing: 12

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                Label {
                    text: qsTr("Automatic worktree cleanup")
                    color: Theme.palette.color("text", "#e4e4e7")
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                    font.weight: Font.Medium
                }

                Label {
                    Layout.fillWidth: true
                    text: {
                        const mode = storage.settings?.mode;
                        if (mode?.mixed) return qsTr("Mixed across selected machines");
                        if (mode?.value === "off") return qsTr("Keep this project's worktrees until you delete them manually.");
                        if (mode?.value === "custom") return qsTr("Use these rules for this project.");
                        return qsTr("Use each machine's worktree cleanup settings.");
                    }
                    color: storage.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    wrapMode: Text.Wrap
                }
            }

            ShellComboBox {
                objectName: "control"
                enabled: storage.editable
                outline: true
                implicitWidth: 140
                readonly property var modes: ["inherit", "off", "custom"]
                model: [qsTr("Inherit"), qsTr("Off"), qsTr("Custom")]
                currentIndex: storage.settings?.mode?.mixed ? -1 : modes.indexOf(storage.settings?.mode?.value ?? "inherit")
                displayText: storage.settings?.mode?.mixed ? qsTr("Mixed") : currentText
                Accessible.name: qsTr("Automatic worktree cleanup")
                onActivated: index => Shell.dispatch("storageSettings.mode", { mode: modes[index] })
            }
        }

        Repeater {
            model: storage.settings?.worktrees ?? []
            delegate: Rule {}
        }

        Label {
            visible: (storage.settings?.artifacts ?? []).length > 0
            text: qsTr("Artifacts and logs")
            color: storage.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
            font.weight: Font.DemiBold
        }

        Repeater {
            model: storage.settings?.artifacts ?? []
            delegate: Rule {}
        }
    }
}
