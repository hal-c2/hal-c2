import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → Notifications, in a client that receives its MC's pushes
// (`notifications`, apps/mobile-qt's Notifications): alerts on this device,
// which UnifiedPush distributor carries them, the ongoing activity card, and
// quiet hours. The system owns the permission, so turning alerts off opens
// its settings.
SettingsPage {
    id: page

    readonly property var notifications: Shell.state.notifications ?? null
    readonly property bool supported: notifications !== null && notifications.supported === true
    readonly property var quietHours: notifications !== null ? (notifications.quietHours ?? null) : null
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")

    // "22:00" for 1320 minutes after midnight, and back; -1 when it is not a time.
    function clock(minutes) {
        const hours = Math.floor(minutes / 60);
        const rest = minutes % 60;
        return (hours < 10 ? "0" : "") + hours + ":" + (rest < 10 ? "0" : "") + rest;
    }
    function minutes(text) {
        const match = /^(\d{1,2}):(\d{2})$/.exec(text.trim());
        if (!match || Number(match[1]) > 23 || Number(match[2]) > 59) return -1;
        return Number(match[1]) * 60 + Number(match[2]);
    }

    objectName: "notificationsSettings"
    title: qsTr("Notifications")

    ColumnLayout {
        Layout.fillWidth: true
        spacing: 8

        Label {
            objectName: "notificationsUnsupported"
            Layout.fillWidth: true
            Layout.topMargin: 12
            visible: !page.supported
            text: qsTr("This build of HAL-C2 cannot receive notifications. Install a newer build to get them.")
            color: page.muted
            font.pixelSize: Math.round(13 * Theme.fontScale)
            wrapMode: Text.Wrap
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 12
            visible: page.supported
            spacing: 8

            Label {
                Layout.fillWidth: true
                text: qsTr("Alerts on this device")
                color: page.foreground
                font.pixelSize: Math.round(14 * Theme.fontScale)
                font.weight: Font.DemiBold
                wrapMode: Text.Wrap
            }

            ShellSwitch {
                objectName: "notificationsDevice"
                checked: page.notifications?.enabled ?? false
                Accessible.name: qsTr("Alerts on this device")
                onToggled: {
                    Shell.dispatch(checked ? "notifications.enable" : "notifications.disable");
                    checked = Qt.binding(() => page.notifications?.enabled ?? false);
                }
            }
        }

        Label {
            objectName: "notificationsStatus"
            Layout.fillWidth: true
            visible: page.supported
            text: page.notifications?.enabled ? qsTr("Notifications are enabled.") : qsTr("Notifications are disabled.")
            color: page.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
            wrapMode: Text.Wrap
        }

        Label {
            objectName: "notificationsPermission"
            Layout.fillWidth: true
            visible: page.supported
            text: {
                const permission = page.notifications?.permission ?? "ask";
                if (permission === "granted") return qsTr("System permission: Allowed");
                if (permission === "denied") return qsTr("System permission: Blocked");
                return qsTr("System permission: Not asked yet");
            }
            color: page.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
            wrapMode: Text.Wrap
        }

        Label {
            objectName: "notificationsMessage"
            Layout.fillWidth: true
            visible: text.length > 0
            text: page.notifications?.message ?? ""
            color: Theme.palette.color("warning", "#fbbf24")
            font.pixelSize: Math.round(12 * Theme.fontScale)
            wrapMode: Text.Wrap
        }

        ShellButton {
            objectName: "notificationsOpenSettings"
            visible: page.supported
            text: qsTr("Open system settings")
            onClicked: Shell.dispatch("notifications.openSettings")
        }

        // Which UnifiedPush distributor carries the MC's pushes, when more
        // than one is installed.
        Label {
            Layout.fillWidth: true
            Layout.topMargin: 12
            visible: page.supported && (page.notifications?.distributors ?? []).length > 0
            text: page.notifications?.choosing ? qsTr("Pick the app that delivers notifications")
                                               : qsTr("Delivered by")
            color: page.foreground
            font.pixelSize: Math.round(13 * Theme.fontScale)
            font.weight: Font.DemiBold
        }

        Repeater {
            model: page.supported ? (page.notifications?.distributors ?? []) : []

            delegate: ShellButton {
                required property var modelData
                objectName: "notificationsDistributor:" + modelData.id
                text: modelData.label + (modelData.id === page.notifications?.distributor ? qsTr(" (in use)") : "")
                onClicked: Shell.dispatch("notifications.pickDistributor", { id: modelData.id })
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 12
            visible: page.supported
            spacing: 8

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                Label {
                    Layout.fillWidth: true
                    text: qsTr("Ongoing agent activity")
                    color: page.foreground
                    font.pixelSize: Math.round(14 * Theme.fontScale)
                    font.weight: Font.DemiBold
                    wrapMode: Text.Wrap
                }
                Label {
                    Layout.fillWidth: true
                    text: qsTr("A card that follows the agents' work, on the lock screen too.")
                    color: page.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    wrapMode: Text.Wrap
                }
            }

            ShellSwitch {
                objectName: "notificationsLiveActivity"
                checked: page.notifications?.liveActivity ?? false
                Accessible.name: qsTr("Ongoing agent activity")
                onToggled: {
                    Shell.dispatch("notifications.setLiveActivity", { on: checked });
                    checked = Qt.binding(() => page.notifications?.liveActivity ?? false);
                }
            }
        }

        ShellButton {
            objectName: "notificationsLiveUpdateSettings"
            visible: page.supported && page.notifications?.liveUpdates === true
            text: qsTr("Live update settings")
            onClicked: Shell.dispatch("notifications.openLiveUpdateSettings")
        }

        // Quiet hours, kept by the MC: alerts wait for them to end.
        Label {
            Layout.fillWidth: true
            Layout.topMargin: 12
            visible: page.supported
            text: qsTr("Quiet hours")
            color: page.foreground
            font.pixelSize: Math.round(14 * Theme.fontScale)
            font.weight: Font.DemiBold
        }

        Label {
            objectName: "notificationsQuietHoursState"
            Layout.fillWidth: true
            visible: page.supported
            text: page.quietHours !== null
                  ? qsTr("Alerts wait from %1 to %2.").arg(page.clock(page.quietHours.start)).arg(page.clock(page.quietHours.end))
                  : qsTr("Off")
            color: page.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
            wrapMode: Text.Wrap
        }

        RowLayout {
            visible: page.supported
            spacing: 8

            ShellTextField {
                id: quietStart
                objectName: "notificationsQuietStart"
                Layout.preferredWidth: 72
                placeholderText: "22:00"
                text: page.quietHours !== null ? page.clock(page.quietHours.start) : ""
            }
            Label {
                text: qsTr("to")
                color: page.muted
            }
            ShellTextField {
                id: quietEnd
                objectName: "notificationsQuietEnd"
                Layout.preferredWidth: 72
                placeholderText: "07:00"
                text: page.quietHours !== null ? page.clock(page.quietHours.end) : ""
            }
        }

        RowLayout {
            visible: page.supported
            spacing: 8

            ShellSwitch {
                id: allowApprovals
                objectName: "notificationsQuietAllowApprovals"
                checked: page.quietHours?.allowApprovals ?? false
            }
            Label {
                Layout.fillWidth: true
                text: qsTr("Let approval requests through")
                color: page.foreground
                wrapMode: Text.Wrap
            }
        }

        RowLayout {
            visible: page.supported
            spacing: 8

            ShellButton {
                objectName: "notificationsQuietSave"
                text: qsTr("Set quiet hours")
                enabled: page.minutes(quietStart.text) >= 0 && page.minutes(quietEnd.text) >= 0
                onClicked: Shell.dispatch("notifications.setQuietHours", {
                    quietHours: { start: page.minutes(quietStart.text), end: page.minutes(quietEnd.text), allowApprovals: allowApprovals.checked }
                })
            }
            ShellButton {
                objectName: "notificationsQuietOff"
                visible: page.quietHours !== null
                text: qsTr("Turn off")
                onClicked: Shell.dispatch("notifications.setQuietHours", { quietHours: null })
            }
        }
    }
}
