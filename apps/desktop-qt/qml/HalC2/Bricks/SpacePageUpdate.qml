pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// What the open page's update is and how it last went (Spaces.page.schedule):
// its instruction, its cadence, when it next runs and was last written, and a
// failed run. Times are the clock's, not "5m ago", so nothing here goes stale.
// `actions` shows the way to run, pause, change and remove it; a page in the
// trash shows no way, the MC would refuse it.
Rectangle {
    id: card

    readonly property var schedule: Spaces.page.schedule ?? ({})
    readonly property bool trashed: Spaces.page.trashed === true
    readonly property bool active: schedule.enabled === true
    readonly property bool running: schedule.lastRunStatus === "running"
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    property bool actions: true

    signal changeRequested

    function clock(iso) {
        return new Date(iso).toLocaleString(Qt.locale(), Locale.ShortFormat);
    }

    function whenText() {
        const cadence = schedule.cadenceLabel ?? "";
        if (trashed)
            return qsTr("%1, stopped while this page is in the trash").arg(cadence);
        if (!active)
            return qsTr("%1, paused").arg(cadence);
        return schedule.nextRunAt ? qsTr("%1, next run %2").arg(cadence).arg(clock(schedule.nextRunAt)) : cadence;
    }

    objectName: "spacePageUpdate"
    visible: (schedule.instruction ?? "") !== ""
    implicitHeight: content.implicitHeight + 16
    radius: Math.min(Theme.radius, 8)
    color: Qt.alpha(Theme.palette.color("accent", "#3b82f6"), 0.08)
    border.color: Qt.alpha(Theme.palette.color("accent", "#3b82f6"), 0.3)

    ColumnLayout {
        id: content

        anchors.fill: parent
        anchors.margins: 8
        spacing: 4

        Text {
            objectName: "spaceUpdateSays"
            Layout.fillWidth: true
            text: card.schedule.instruction ?? ""
            color: card.foreground
            wrapMode: Text.Wrap
            font.pixelSize: Math.round(13 * Theme.fontScale)
        }

        Text {
            objectName: "spaceUpdateWhen"
            Layout.fillWidth: true
            text: card.whenText()
            color: card.muted
            wrapMode: Text.Wrap
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        Text {
            objectName: "spaceUpdateWritten"
            Layout.fillWidth: true
            text: card.running ? qsTr("Writing now…")
                : (Spaces.page.writtenAt ?? "") !== "" ? qsTr("Last written %1").arg(card.clock(Spaces.page.writtenAt))
                : qsTr("Not written yet")
            color: card.muted
            wrapMode: Text.Wrap
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        Text {
            objectName: "spaceUpdateFailure"
            Layout.fillWidth: true
            visible: card.schedule.lastRunStatus === "failed"
            text: qsTr("Last run failed: %1").arg(card.schedule.lastRunError || qsTr("unknown error"))
            color: Theme.palette.color("error", "#ef4444")
            wrapMode: Text.Wrap
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        Flow {
            Layout.fillWidth: true
            visible: card.actions && !card.trashed
            spacing: 4

            ShellButton {
                objectName: "spaceUpdateRun"
                enabled: !card.running
                text: qsTr("Run now")
                onClicked: Shell.dispatch("space.page.schedule.runNow", { pageId: Spaces.pageId })
            }

            ShellButton {
                objectName: "spaceUpdatePause"
                text: card.active ? qsTr("Pause") : qsTr("Resume")
                onClicked: Shell.dispatch("space.page.schedule.setEnabled", { pageId: Spaces.pageId, enabled: !card.active })
            }

            ShellButton {
                objectName: "spaceUpdateChange"
                text: qsTr("Change")
                onClicked: card.changeRequested()
            }

            ShellButton {
                objectName: "spaceUpdateRemove"
                text: qsTr("Remove")
                tint: Theme.palette.color("error", "#ef4444")
                onClicked: Shell.dispatch("space.page.schedule.remove", { pageId: Spaces.pageId })
            }
        }
    }
}
