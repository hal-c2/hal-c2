import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → General's version of the desktop app and its updates
// (DesktopUpdateController's `desktopUpdate`): where the update stands, a
// check, and the switch between the Stable and Nightly tracks, which this
// device keeps. Hidden where the app cannot update itself at all.
ColumnLayout {
    id: updates

    readonly property var update: Shell.state.desktopUpdate ?? null
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color warning: Theme.palette.color("warning", "#fbbf24")

    objectName: "desktopUpdateSettings"
    Layout.fillWidth: true
    visible: update !== null && update.shown === true
    spacing: 8

    RowLayout {
        Layout.fillWidth: true
        spacing: 12

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Label {
                text: qsTr("Version %1").arg(updates.update?.currentVersion ?? "")
                color: updates.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.Medium
            }

            Label {
                objectName: "desktopUpdateStatus"
                Layout.fillWidth: true
                text: updates.update?.state?.message || (updates.update?.label ?? "")
                color: updates.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }
        }

        ShellButton {
            objectName: "desktopUpdateCheck"
            text: qsTr("Check for Updates")
            enabled: updates.update?.canCheck === true && updates.update?.state?.enabled === true
            onClicked: Shell.dispatch("desktopUpdate.check")
        }
    }

    ShellSwitch {
        objectName: "desktopUpdateNightly"
        text: qsTr("Nightly builds")
        checked: updates.update?.track === "Nightly"
        enabled: updates.update?.canChangeTrack === true
        onToggled: Shell.dispatch("desktopUpdate.setTrack", {
            channel: checked ? "nightly" : "latest"
        })
    }

    Label {
        objectName: "desktopUpdateWarning"
        Layout.fillWidth: true
        visible: (updates.update?.warning ?? null) !== null
        text: updates.update?.warning ? updates.update.warning.title + ". " + updates.update.warning.description : ""
        color: updates.warning
        font.pixelSize: Math.round(12 * Theme.fontScale)
        wrapMode: Text.Wrap
    }
}
