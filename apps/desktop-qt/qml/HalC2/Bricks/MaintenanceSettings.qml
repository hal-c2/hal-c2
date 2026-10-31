pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → Maintenance, in a client that maintains its environments itself
// (`maintenance`, apps/mobile-qt's Maintenance): each machine's HAL-C2
// version, the newest release on its channel and the update to it, and its
// enabled providers with theirs. A machine the client cannot operate says why
// instead. Providers and permissions are read while the page shows.
SettingsPage {
    id: page

    readonly property var model: Shell.state.maintenance ?? null
    readonly property var machines: model !== null ? model.machines : []
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color success: Theme.palette.color("success", "#22c55e")
    readonly property color error: Theme.palette.color("error", "#f87171")

    objectName: "maintenanceSettings"
    title: qsTr("Maintenance")

    Component.onCompleted: Shell.dispatch("maintenance.open")
    Component.onDestruction: Shell.dispatch("maintenance.close")

    ColumnLayout {
        Layout.fillWidth: true
        Layout.topMargin: 12
        spacing: 12

        Label {
            objectName: "maintenanceAppVersion"
            Layout.fillWidth: true
            visible: page.model !== null
            text: page.model !== null && page.model.appVersion
                  ? qsTr("This app is %1. An environment behind it can be updated to match.").arg(page.model.appVersion)
                  : qsTr("This app does not know its own version.")
            color: page.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
            wrapMode: Text.Wrap
        }

        Label {
            objectName: "maintenanceMessage"
            Layout.fillWidth: true
            visible: page.model !== null && page.model.message !== null
            text: visible ? page.model.message.text : ""
            color: visible && page.model.message.ok ? page.success : page.error
            font.pixelSize: Math.round(12 * Theme.fontScale)
            wrapMode: Text.Wrap
        }

        // The desktop apps that close to update, asked about first.
        Rectangle {
            objectName: "maintenanceConfirm"
            Layout.fillWidth: true
            visible: page.model !== null && page.model.confirm !== null
            implicitHeight: confirmColumn.implicitHeight + 24
            radius: 8
            color: "transparent"
            border.color: Theme.palette.color("warning", "#f59e0b")
            border.width: 1

            ColumnLayout {
                id: confirmColumn

                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                Label {
                    objectName: "maintenanceConfirmText"
                    Layout.fillWidth: true
                    text: page.model !== null && page.model.confirm !== null ? page.model.confirm.text : ""
                    color: page.foreground
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                    wrapMode: Text.Wrap
                }

                RowLayout {
                    spacing: 8

                    ShellButton {
                        objectName: "maintenanceConfirmUpdate"
                        primary: true
                        text: qsTr("Update")
                        onClicked: Shell.dispatch("maintenance.confirm")
                    }

                    ShellButton {
                        objectName: "maintenanceConfirmCancel"
                        text: qsTr("Cancel")
                        onClicked: Shell.dispatch("maintenance.cancel")
                    }
                }
            }
        }

        ShellButton {
            objectName: "maintenanceUpdateAll"
            visible: page.model !== null && page.model.updatable > 1
            primary: true
            text: qsTr("Update all machines")
            onClicked: Shell.dispatch("maintenance.updateAll")
        }

        Repeater {
            model: page.model !== null ? page.model.groups : []

            delegate: ShellButton {
                required property var modelData

                objectName: "maintenanceUpdateProviders-" + modelData.driver
                text: qsTr("Update %1 on %2 machines").arg(modelData.name).arg(modelData.count)
                onClicked: Shell.dispatch("maintenance.updateProviders", { driver: modelData.driver })
            }
        }

        Repeater {
            model: page.machines

            delegate: ColumnLayout {
                id: machine

                required property var modelData
                readonly property string environmentId: modelData.environmentId
                readonly property bool may: modelData.blocked.length === 0

                objectName: "maintenanceMachine-" + environmentId
                Layout.fillWidth: true
                Layout.topMargin: 8
                spacing: 6

                Label {
                    Layout.fillWidth: true
                    text: machine.modelData.label
                    color: page.foreground
                    font.pixelSize: Math.round(14 * Theme.fontScale)
                    font.weight: Font.DemiBold
                    wrapMode: Text.Wrap
                }

                Label {
                    objectName: "maintenanceVersion-" + machine.environmentId
                    Layout.fillWidth: true
                    text: !machine.modelData.online ? qsTr("Offline")
                          : machine.modelData.version ? qsTr("Version %1").arg(machine.modelData.version)
                          : qsTr("Unknown version")
                    color: page.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }

                Label {
                    objectName: "maintenanceBlocked-" + machine.environmentId
                    Layout.fillWidth: true
                    visible: !machine.may
                    text: machine.modelData.blocked
                    color: page.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    wrapMode: Text.Wrap
                }

                Label {
                    objectName: "maintenanceRelease-" + machine.environmentId
                    Layout.fillWidth: true
                    visible: machine.modelData.release !== null
                    text: !visible ? "" : machine.modelData.release.checking ? qsTr("Checking for updates…") : machine.modelData.release.text
                    color: page.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    wrapMode: Text.Wrap
                }

                Label {
                    objectName: "maintenanceOutcome-" + machine.environmentId
                    Layout.fillWidth: true
                    visible: machine.modelData.outcome !== null
                    text: visible ? machine.modelData.outcome.text : ""
                    color: visible && machine.modelData.outcome.ok ? page.success : page.error
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    wrapMode: Text.Wrap
                }

                // What updating this server takes, when it is behind.
                Label {
                    Layout.fillWidth: true
                    visible: machine.may && machine.modelData.target.length > 0 && machine.modelData.path === "desktop-manual"
                    text: qsTr("Update the desktop app on that machine to update this server.")
                    color: page.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    wrapMode: Text.Wrap
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: 8
                    visible: machine.may

                    ShellButton {
                        objectName: "maintenanceCheck-" + machine.environmentId
                        text: qsTr("Check for updates")
                        enabled: machine.modelData.release === null || !machine.modelData.release.checking
                        onClicked: Shell.dispatch("maintenance.check", { environment: machine.environmentId })
                    }

                    ShellButton {
                        objectName: "maintenanceUpdate-" + machine.environmentId
                        visible: machine.modelData.target.length > 0 && (machine.modelData.path === "update" || machine.modelData.path === "desktop")
                        enabled: !machine.modelData.updating
                        primary: true
                        text: machine.modelData.updating ? qsTr("Updating…")
                              : machine.modelData.path === "desktop" ? qsTr("Update the desktop app to %1").arg(machine.modelData.target)
                              : qsTr("Update to %1").arg(machine.modelData.target)
                        onClicked: Shell.dispatch("maintenance.update", { environment: machine.environmentId })
                    }

                    ShellButton {
                        objectName: "maintenanceCopyCommand-" + machine.environmentId
                        visible: machine.modelData.target.length > 0 && machine.modelData.path === "command"
                        text: qsTr("Copy update command")
                        onClicked: Shell.dispatch("maintenance.copyCommand", { environment: machine.environmentId })
                    }

                    ShellButton {
                        objectName: "maintenanceRefresh-" + machine.environmentId
                        text: qsTr("Refresh providers")
                        onClicked: Shell.dispatch("maintenance.refreshProviders", { environment: machine.environmentId })
                    }
                }

                Label {
                    Layout.fillWidth: true
                    visible: machine.modelData.providersError.length > 0
                    text: machine.modelData.providersError
                    color: page.error
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    wrapMode: Text.Wrap
                }

                Repeater {
                    model: machine.modelData.providers

                    delegate: ColumnLayout {
                        id: provider

                        required property var modelData
                        readonly property string key: machine.environmentId + "-" + modelData.instanceId

                        objectName: "maintenanceProvider-" + key
                        Layout.fillWidth: true
                        Layout.leftMargin: 12
                        spacing: 4

                        Label {
                            Layout.fillWidth: true
                            text: provider.modelData.name
                            color: page.foreground
                            font.pixelSize: Math.round(13 * Theme.fontScale)
                        }

                        Label {
                            Layout.fillWidth: true
                            visible: text.length > 0
                            text: [provider.modelData.version, provider.modelData.latest ? qsTr("Latest %1").arg(provider.modelData.latest) : ""]
                                  .filter(part => part.length > 0).join(" · ")
                            color: page.muted
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }

                        Label {
                            objectName: "maintenanceProviderStatus-" + provider.key
                            Layout.fillWidth: true
                            visible: text.length > 0
                            text: provider.modelData.outcome.length > 0 ? provider.modelData.outcome
                                  : provider.modelData.updating ? (provider.modelData.status.length > 0 ? provider.modelData.status : qsTr("Updating…"))
                                  : ""
                            color: provider.modelData.failed ? page.error
                                   : provider.modelData.outcome.length > 0 ? page.success : page.muted
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            wrapMode: Text.Wrap
                        }

                        ShellButton {
                            objectName: "maintenanceUpdateProvider-" + provider.key
                            visible: provider.modelData.canUpdate
                            text: qsTr("Update %1").arg(provider.modelData.name)
                            onClicked: Shell.dispatch("maintenance.updateProvider", {
                                environment: machine.environmentId,
                                instanceId: provider.modelData.instanceId
                            })
                        }
                    }
                }
            }
        }
    }
}
