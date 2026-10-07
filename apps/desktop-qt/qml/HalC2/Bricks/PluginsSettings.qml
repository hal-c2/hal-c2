pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → Plugins: the UI plugins this device has (`Shell.state.plugins`,
// the plugin controller's), each turned off and on or removed, the ones that
// failed with what went wrong, and a plugin file loaded from a URL once the
// user has been told nothing vouches for it.
SettingsPage {
    id: page

    readonly property var settings: Shell.state.plugins ?? null
    readonly property var items: settings?.items ?? []
    readonly property var disabled: settings?.disabled ?? []
    readonly property var failed: settings?.failed ?? []
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
