import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → Integrations, natively (DeviceSettingsController's
// `deviceSettings`): the device hub and agent device access on the selected
// environments, and one environment's device status.
SettingsPage {
    id: page

    readonly property var state: Shell.state.deviceSettings ?? null
    readonly property bool idle: (state?.pending ?? "") === ""
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color warning: Theme.palette.color("warning", "#fbbf24")
    readonly property color danger: Theme.palette.color("error", "#ef4444")

    function send(name, payload) {
        Shell.dispatch("deviceSettings." + name, payload ?? {});
    }

    objectName: "integrationsSettings"
    title: qsTr("Integrations")

    component Caption: Label {
        Layout.fillWidth: true
        color: page.muted
        font.pixelSize: 12
        wrapMode: Text.Wrap
    }

    // The hub or agent access: its switch, the tool's version, and an update
    // when one is offered.
    component Toggle: ColumnLayout {
        id: toggle

        property string tool
        property string title
        property string description
        readonly property var entry: page.state?.[tool] ?? null

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
                    color: page.foreground
                    font.pixelSize: 13
                    font.weight: Font.Medium
                }

                Label {
                    objectName: "mixed"
                    visible: toggle.entry?.mixed ?? false
                    text: qsTr("Mixed across selected machines")
                    color: page.warning
                    font.pixelSize: 12
                }

                Caption {
                    text: toggle.description
                }
            }

            Label {
                objectName: "version"
                text: toggle.entry?.version ?? ""
                color: page.muted
                font.pixelSize: 12
                font.family: "monospace"
            }

            Label {
                objectName: "status"
                visible: text.length > 0
                text: toggle.entry?.status ?? ""
                color: page.muted
                font.pixelSize: 12
            }

            Switch {
                objectName: "control"
                enabled: toggle.entry?.enabled ?? false
                checked: toggle.entry?.on ?? false
                Accessible.name: toggle.title
                onToggled: page.send(toggle.tool, { enabled: checked })
            }
        }

        RowLayout {
            spacing: 8
            visible: update.visible || check.visible

            ShellButton {
                id: update
                objectName: "update"
                visible: (toggle.entry?.update ?? "") !== ""
                enabled: page.idle && !(page.state?.busy ?? false)
                text: page.state?.pending === "update-" + toggle.tool ? qsTr("Updating…") : (toggle.entry?.update ?? "")
                onClicked: page.send("update", { tool: toggle.tool })
            }

            ShellButton {
                id: check
                objectName: "check"
                visible: page.state?.canCheck ?? false
                enabled: page.idle && !(page.state?.busy ?? false)
                subtle: true
                text: page.state?.pending === "check" ? qsTr("Checking…") : qsTr("Check versions")
                onClicked: page.send("check")
            }
        }

        Label {
            objectName: "updateError"
            visible: page.state?.updateError?.tool === toggle.tool
            Layout.fillWidth: true
            text: page.state?.updateError?.message ?? ""
            color: page.danger
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }
    }

    SettingsScopeSentence {}

    Label {
        text: qsTr("Devices")
        color: page.muted
        font.pixelSize: 12
        font.weight: Font.DemiBold
    }

    Toggle {
        tool: "hub"
        title: qsTr("Device hub")
        description: qsTr("Enable this environment to open simulators and emulators, whether they run here or on a remote device host.")
    }

    ColumnLayout {
        objectName: "platforms"
        visible: (page.state?.platforms ?? []).length > 0
        Layout.fillWidth: true
        spacing: 6

        RowLayout {
            Layout.fillWidth: true

            Caption {
                objectName: "statusNote"
                visible: text.length > 0
                text: page.state?.statusNote ?? ""
            }

            Item {
                Layout.fillWidth: true
            }

            ShellButton {
                objectName: "refresh"
                subtle: true
                enabled: page.idle && (page.state?.hub?.on ?? false) && !(page.state?.busy ?? false)
                text: page.state?.pending === "check" ? qsTr("Checking…") : qsTr("Refresh")
                onClicked: page.send("refresh")
            }
        }

        Repeater {
            model: page.state?.platforms ?? []

            delegate: RowLayout {
                required property var modelData
                objectName: "platform:" + modelData.platform
                Layout.fillWidth: true
                spacing: 8

                Label {
                    text: modelData.platform
                    color: page.foreground
                    font.pixelSize: 13
                    font.weight: Font.Medium
                }

                Caption {
                    objectName: "message"
                    text: modelData.ready ? qsTr("Ready") : modelData.message
                }
            }
        }
    }

    Toggle {
        tool: "agent"
        title: qsTr("Agent device access")
        description: qsTr("Allow new agent sessions in this environment to start and control local and remote devices, with required tools set up automatically.")
    }

    Repeater {
        model: page.state?.hosts ?? []

        delegate: RowLayout {
            required property var modelData
            objectName: "host:" + modelData.id
            Layout.fillWidth: true
            spacing: 12

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                Label {
                    text: modelData.label
                    color: page.foreground
                    font.pixelSize: 12
                    font.weight: Font.Medium
                }

                Caption {
                    text: modelData.message
                }

                Caption {
                    visible: modelData.failed
                    text: qsTr("Check the host connection and network access, then retry. Your device settings are saved.")
                }
            }

            ShellButton {
                objectName: "retry"
                visible: modelData.canRetry
                enabled: page.idle
                text: page.state?.pending === "retry" ? qsTr("Retrying…") : qsTr("Retry")
                onClicked: page.send("retry", { hostId: modelData.id })
            }
        }
    }
}
