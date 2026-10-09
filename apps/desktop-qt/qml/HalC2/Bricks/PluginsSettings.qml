pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → Plugins: the plugins each MC runs (`Shell.state.mcPlugins`), by
// environment, with what they are, enabled once the user accepts what they
// ask for; then the UI plugins this device has (`Shell.state.plugins`, the
// plugin controller's), each turned off and on or removed, the ones that
// failed with what went wrong, and a plugin file loaded from a URL once the
// user has been told nothing vouches for it.
SettingsPage {
    id: page

    readonly property var settings: Shell.state.plugins ?? null
    readonly property var items: settings?.items ?? []
    readonly property var disabled: settings?.disabled ?? []
    readonly property var failed: settings?.failed ?? []
    // Every MC, with plugins or not: one with none yet can still look in its folder.
    readonly property var mcEnvironments: Shell.state.mcPlugins?.environments ?? []
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
    // Keeps the plugins loaded while only this page shows.
    readonly property int loadedRevision: PluginRegistry.revision

    objectName: "pluginsSettings"
    title: qsTr("Plugins")

    component PluginRow: RowLayout {
        id: row

        required property string pluginId
        required property string detail
        required property bool enabled_

        objectName: "plugin:" + pluginId
        Layout.fillWidth: true
        spacing: 12

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Label {
                objectName: "pluginName"
                text: row.pluginId
                color: Theme.palette.color("text", "#e4e4e7")
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.Medium
            }

            Label {
                objectName: "pluginDetail"
                Layout.fillWidth: true
                text: row.detail
                color: Theme.palette.color("textMuted", "#a1a1aa")
                elide: Text.ElideMiddle
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }
        }

        ShellButton {
            objectName: "pluginToggle"
            text: row.enabled_ ? qsTr("Disable") : qsTr("Enable")
            onClicked: Shell.dispatch(row.enabled_ ? "plugins.disable" : "plugins.enable", { id: row.pluginId })
        }

        ShellButton {
            objectName: "pluginRemove"
            subtle: true
            iconName: "trash"
            Accessible.name: qsTr("Remove %1").arg(row.pluginId)
            onClicked: Shell.dispatch("plugins.remove", { id: row.pluginId })
        }
    }

    component McPluginCard: ColumnLayout {
        id: card

        required property var plugin
        readonly property bool running: plugin.status === "running"
        readonly property bool failed: plugin.status === "failed" || plugin.status === "error"
        readonly property bool off: plugin.status === "disabled" || plugin.status === "awaitingConsent"
        // Why a package did not load, else why its MC part last stopped.
        readonly property string reason: plugin.error || plugin.lastError || ""

        objectName: "mcPlugin:" + plugin.environment + "/" + plugin.id
        Layout.fillWidth: true
        spacing: 6

        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            Image {
                Layout.preferredWidth: 32
                Layout.preferredHeight: 32
                visible: card.plugin.iconUrl.length > 0
                source: card.plugin.iconUrl
                sourceSize: Qt.size(64, 64)
                fillMode: Image.PreserveAspectFit
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                Label {
                    objectName: "mcPluginName"
                    text: card.plugin.name || card.plugin.id
                    color: page.foreground
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                    font.weight: Font.Medium
                }

                Label {
                    objectName: "mcPluginByline"
                    Layout.fillWidth: true
                    text: [card.plugin.version, card.plugin.author?.name ?? ""].filter(part => part.length > 0).join(" · ")
                    color: page.muted
                    elide: Text.ElideRight
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }
            }

            ShellButton {
                objectName: "mcPluginRestart"
                text: qsTr("Restart")
                // A package that did not load is fixed in its files, not by a restart.
                visible: card.running || card.plugin.status === "failed"
                onClicked: Shell.dispatch("mcPlugins.restart", { environment: card.plugin.environment, id: card.plugin.id })
            }

            ShellButton {
                objectName: "mcPluginSettings"
                text: qsTr("Settings")
                visible: card.plugin.settingsSchema.length > 0 || card.plugin.settingsPageUrl.length > 0
                onClicked: Shell.dispatch("settings.navigate", { to: "/settings/plugin/" + card.plugin.environment + "/" + card.plugin.id })
            }

            ShellButton {
                objectName: "mcPluginToggle"
                text: card.off ? qsTr("Enable") : qsTr("Disable")
                enabled: card.plugin.status !== "incompatible"
                onClicked: Shell.dispatch(card.off ? "mcPlugins.enable" : "mcPlugins.disable", { environment: card.plugin.environment, id: card.plugin.id })
            }
        }

        Label {
            objectName: "mcPluginDescription"
            Layout.fillWidth: true
            visible: text.length > 0
            text: card.plugin.description
            color: page.foreground
            wrapMode: Text.Wrap
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        Label {
            objectName: "mcPluginStatus"
            Layout.fillWidth: true
            text: {
                switch (card.plugin.status) {
                case "running":
                    return qsTr("Running");
                case "disabled":
                    return qsTr("Disabled");
                case "awaitingConsent":
                    return qsTr("Waiting for you to accept what it asks for");
                case "incompatible":
                    return qsTr("Not made for this MC: %1").arg(card.reason);
                default:
                    return qsTr("Failed: %1").arg(card.reason);
                }
            }
            color: card.failed || card.plugin.status === "incompatible" ? page.errorColor : page.muted
            wrapMode: Text.Wrap
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        Flow {
            Layout.fillWidth: true
            visible: card.plugin.screenshotUrls.length > 0
            spacing: 8

            Repeater {
                model: card.plugin.screenshotUrls

                delegate: Image {
                    required property var modelData

                    objectName: "mcPluginScreenshot"
                    width: 200
                    height: 125
                    source: modelData.url
                    sourceSize: Qt.size(400, 250)
                    fillMode: Image.PreserveAspectFit
                    Accessible.role: Accessible.Graphic
                    Accessible.name: modelData.caption ?? ""
                }
            }
        }
    }

    Repeater {
        model: page.mcEnvironments

        delegate: ColumnLayout {
            id: environment

            required property var modelData

            objectName: "mcPlugins:" + modelData.id
            Layout.fillWidth: true
            Layout.bottomMargin: 8
            spacing: 12

            RowLayout {
                Layout.fillWidth: true

                Label {
                    Layout.fillWidth: true
                    text: qsTr("On %1").arg(environment.modelData.label)
                    color: page.foreground
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                    font.weight: Font.DemiBold
                }

                // The MC lists a plugin put in its plugins folder once it looks again.
                ShellButton {
                    objectName: "mcPluginsRescan"
                    text: qsTr("Look for plugins")
                    onClicked: Shell.dispatch("mcPlugins.rescan", { environment: environment.modelData.id })
                }
            }

            Repeater {
                model: environment.modelData.plugins

                delegate: McPluginCard {
                    required property var modelData

                    plugin: modelData
                }
            }
        }
    }

    Label {
        Layout.fillWidth: true
        text: qsTr("QML files in %1 that add to the sidebar footer, the composer's actions and the status bar.").arg(page.settings?.dir ?? "")
        color: page.muted
        wrapMode: Text.Wrap
        font.pixelSize: Math.round(12 * Theme.fontScale)
    }

    Label {
        objectName: "pluginsEmpty"
        visible: page.items.length + page.disabled.length === 0
        text: qsTr("No plugins are installed.")
        color: page.muted
        font.pixelSize: Math.round(13 * Theme.fontScale)
    }

    Repeater {
        model: page.items

        delegate: PluginRow {
            required property var modelData

            pluginId: modelData.id
            enabled_: true
            detail: (modelData.shown.length === 0 ? qsTr("Loaded, with nothing shown in this app") : qsTr("Loaded")) + " · " + (modelData.url.length > 0 ? modelData.url : modelData.file)
        }
    }

    Repeater {
        model: page.disabled

        delegate: PluginRow {
            required property var modelData

            pluginId: modelData.id
            enabled_: false
            detail: qsTr("Disabled") + " · " + modelData.file
        }
    }

    Label {
        visible: page.failed.length > 0
        Layout.topMargin: 8
        text: qsTr("Failed")
        color: page.foreground
        font.pixelSize: Math.round(13 * Theme.fontScale)
        font.weight: Font.DemiBold
    }

    Repeater {
        model: page.failed

        delegate: Label {
            required property var modelData

            objectName: "pluginFailure:" + modelData.id
            Layout.fillWidth: true
            text: qsTr("%1: %2").arg(modelData.id).arg(modelData.message)
            color: page.errorColor
            wrapMode: Text.Wrap
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 8
        spacing: 8

        ShellTextField {
            id: address

            objectName: "pluginUrl"
            Layout.fillWidth: true
            placeholderText: qsTr("https://…/plugin.qml")
            Accessible.name: qsTr("Plugin URL")
            onAccepted: load.clicked()
        }

        ShellButton {
            id: load

            objectName: "pluginLoad"
            text: qsTr("Load from URL")
            enabled: address.text.trim().length > 0
            onClicked: {
                Shell.dispatch("plugins.install", { url: address.text.trim() });
                address.clear();
            }
        }
    }
}
