import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → General's background activity (BackgroundActivityController's
// `backgroundActivity`): the profile the selected environments gate their
// background work by, and with Advanced the Git fetch interval and whether
// work pauses while the host is locked.
ColumnLayout {
    id: row

    required property var spec
    readonly property var model: Shell.state.backgroundActivity ?? null
    readonly property var profiles: model?.profiles ?? []
    readonly property bool editable: Shell.state.settingsScope?.editable ?? false
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")

    objectName: "settingsRow:" + spec.id
    Layout.fillWidth: true
    spacing: 6

    RowLayout {
        Layout.fillWidth: true
        spacing: 12

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Label {
                text: row.spec.title
                color: row.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.Medium
            }

            Label {
                Layout.fillWidth: true
                text: row.spec.description
                color: row.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }
        }

        ShellComboBox {
            objectName: "control"
            enabled: row.editable
            outline: true
            implicitWidth: 220
            model: row.profiles
            textRole: "label"
            currentIndex: row.model?.mixed ? -1 : row.profiles.findIndex(profile => profile.value === (row.model?.profile ?? "balanced"))
            displayText: row.model?.mixed ? qsTr("Mixed") : currentText
            Accessible.name: row.spec.title
            onActivated: index => Shell.dispatch("backgroundActivity.profile", { value: row.profiles[index].value })
        }
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: 12
        visible: row.model?.advanced ?? false
        spacing: 12

        Label {
            Layout.fillWidth: true
            text: qsTr("Git fetch interval, in seconds (0 never fetches in the background)")
            color: row.foreground
            font.pixelSize: Math.round(13 * Theme.fontScale)
            wrapMode: Text.Wrap
        }

        ShellSpinBox {
            objectName: "fetchSeconds"
            enabled: row.editable
            from: 0
            to: 86400
            editable: true
            value: row.model?.fetchSeconds ?? 0
            Accessible.name: qsTr("Git fetch interval in seconds")
            onValueModified: Shell.dispatch("backgroundActivity.set", { fetchSeconds: value })
        }
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: 12
        visible: row.model?.advanced ?? false
        spacing: 12

        Label {
            Layout.fillWidth: true
            text: qsTr("Pause background work while the host is locked")
            color: row.foreground
            font.pixelSize: Math.round(13 * Theme.fontScale)
            wrapMode: Text.Wrap
        }

        ShellSwitch {
            objectName: "pauseWhenLocked"
            enabled: row.editable
            checked: row.model?.pauseWhenLocked ?? true
            Accessible.name: qsTr("Pause while the host is locked")
            onToggled: Shell.dispatch("backgroundActivity.set", { pauseWhenLocked: checked })
        }
    }
}
