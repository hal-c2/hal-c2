pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// An ACP Registry agent's own sessions, model providers and sign-out on its
// Providers card (ProviderSettingsController's `providerSettings.acp*`
// actions, the entry's `acp`). Sessions and providers are asked from one of
// the environment's projects.
ColumnLayout {
    id: section

    required property var provider
    readonly property var acp: provider.acp ?? null
    readonly property bool idle: acp !== null && acp.busy.length === 0
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")

    function act(action, extra) {
        Shell.dispatch("providerSettings." + action, Object.assign({ instanceId: section.provider.instanceId }, extra || {}));
    }

    objectName: "acpSessions"
    visible: acp !== null
    spacing: 6

    component Hint: Label {
        Layout.fillWidth: true
        color: section.muted
        font.pixelSize: Math.round(12 * Theme.fontScale)
        wrapMode: Text.Wrap
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 6

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            Label {
                text: qsTr("Native sessions")
                color: section.foreground
                font.pixelSize: Math.round(12 * Theme.fontScale)
                font.weight: Font.Medium
            }

            Hint {
                text: section.acp?.canList && section.acp.projects.length === 0 ? qsTr("Add a project before importing sessions.")
                                                                                : qsTr("Resume agent-owned conversations as HAL-C2 threads.")
            }
        }

        ShellComboBox {
            objectName: "acpProject"
            visible: (section.acp?.projects.length ?? 0) > 1
            enabled: section.idle
            outline: true
            model: (section.acp?.projects ?? []).map(project => project.title)
            currentIndex: Math.max(0, (section.acp?.projects ?? []).findIndex(project => project.id === section.acp.projectId))
            Accessible.name: qsTr("Project")
            onActivated: index => section.act("acpProject", { projectId: section.acp.projects[index].id })
        }

        ShellButton {
            objectName: "acpListSessions"
            visible: section.acp?.canList ?? false
            enabled: section.idle && section.acp.projects.length > 0
            subtle: true
            text: section.acp?.busy === "sessions" ? qsTr("Loading…") : section.acp?.sessions === null ? qsTr("List sessions") : qsTr("Refresh")
            onClicked: section.act("acpSessions")
        }

        ShellButton {
            objectName: "acpLogout"
            visible: section.acp?.canLogout ?? false
            enabled: section.idle
            subtle: true
            text: section.acp?.busy === "logout" ? qsTr("Logging out…") : qsTr("Log out")
            onClicked: section.act("acpLogout")
        }
    }

    Hint {
        visible: section.acp?.sessions !== null && section.acp?.sessions !== undefined && section.acp.sessions.length === 0
        text: qsTr("No native sessions in this project.")
    }

    Repeater {
        model: section.acp?.sessions ?? []

        delegate: RowLayout {
            id: sessionRow

            required property var modelData
            objectName: "acpSession_" + modelData.sessionId
            Layout.fillWidth: true
            spacing: 6

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                Label {
                    Layout.fillWidth: true
                    text: sessionRow.modelData.title
                    color: section.foreground
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    elide: Text.ElideRight
                }

                Hint {
                    visible: text.length > 0
                    text: sessionRow.modelData.updatedAt
                    elide: Text.ElideRight
                }
            }

            ShellButton {
                objectName: "acpImport"
                visible: section.acp.canImport
                enabled: section.idle && !sessionRow.modelData.imported
                subtle: true
                text: sessionRow.modelData.imported ? qsTr("Imported") : qsTr("Import")
                onClicked: section.act("acpImport", { sessionId: sessionRow.modelData.sessionId })
            }

            ShellButton {
                objectName: "acpDelete"
                visible: section.acp.canDelete
                enabled: section.idle
                subtle: true
                iconName: "trash"
                Accessible.name: qsTr("Delete %1").arg(sessionRow.modelData.title)
                onClicked: section.act("acpDelete", { sessionId: sessionRow.modelData.sessionId })
            }
        }
    }

    ShellButton {
        objectName: "acpMoreSessions"
        visible: section.acp?.more ?? false
        enabled: section.idle
        subtle: true
        text: qsTr("Load more")
        onClicked: section.act("acpSessions", { more: true })
    }

    RowLayout {
        Layout.fillWidth: true
        visible: section.acp?.canConfigure ?? false
        spacing: 6

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            Label {
                text: qsTr("Model providers")
                color: section.foreground
                font.pixelSize: Math.round(12 * Theme.fontScale)
                font.weight: Font.Medium
            }

            Hint {
                text: qsTr("Point the agent's model providers at an API. Headers are write-only.")
            }
        }

        ShellButton {
            objectName: "acpListProviders"
            enabled: section.idle && section.acp.projects.length > 0
            subtle: true
            text: section.acp?.busy === "providers" ? qsTr("Loading…") : section.acp?.providers === null ? qsTr("List providers") : qsTr("Refresh")
            onClicked: section.act("acpProviders")
        }
    }

    Repeater {
        model: section.acp?.canConfigure ? (section.acp.providers ?? []) : []

        delegate: ColumnLayout {
            id: providerRow

            required property var modelData
            objectName: "acpProvider_" + modelData.providerId
            Layout.fillWidth: true
            spacing: 4

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Label {
                    Layout.fillWidth: true
                    text: providerRow.modelData.providerId + " · " + (providerRow.modelData.configured ? qsTr("Configured") : qsTr("Disabled"))
                          + (providerRow.modelData.required ? qsTr(" · Required") : "")
                    color: section.foreground
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    elide: Text.ElideRight
                }

                ShellButton {
                    objectName: "acpSaveProvider"
                    enabled: section.idle && baseUrl.text.trim().length > 0 && apiType.currentText.length > 0
                    text: section.acp.busy === "provider" ? qsTr("Saving…") : qsTr("Save")
                    onClicked: section.act("acpSetProvider", {
                        providerId: providerRow.modelData.providerId,
                        apiType: apiType.currentText,
                        baseUrl: baseUrl.text,
                        headers: headers.text
                    })
                }

                ShellButton {
                    objectName: "acpDisableProvider"
                    visible: !providerRow.modelData.required && providerRow.modelData.configured
                    enabled: section.idle
                    subtle: true
                    text: qsTr("Disable")
                    onClicked: section.act("acpDisableProvider", { providerId: providerRow.modelData.providerId })
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                ShellComboBox {
                    id: apiType

                    objectName: "acpApiType"
                    outline: true
                    model: providerRow.modelData.supported
                    currentIndex: Math.max(0, providerRow.modelData.supported.indexOf(providerRow.modelData.apiType))
                    Accessible.name: qsTr("%1 protocol").arg(providerRow.modelData.providerId)
                }

                ShellTextField {
                    id: baseUrl

                    objectName: "acpBaseUrl"
                    Layout.fillWidth: true
                    text: providerRow.modelData.baseUrl
                    placeholderText: qsTr("https://api.example.com")
                    Accessible.name: qsTr("%1 base URL").arg(providerRow.modelData.providerId)
                }
            }

            ShellTextField {
                id: headers

                objectName: "acpHeaders"
                Layout.fillWidth: true
                placeholderText: qsTr("{\"Authorization\": \"Bearer …\"}")
                font.family: "monospace"
                Accessible.name: qsTr("%1 write-only headers JSON").arg(providerRow.modelData.providerId)
            }
        }
    }
}
