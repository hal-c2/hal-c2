import QtQuick
import HalC2.Shell

// Beside a planner thread's row in the thread list: where its run is, or what it
// proposes. A thread whose run is gone, discarded or pruned, still came from the
// planner, so its mark stays with the kind's name ("Planner" or "Task"). Follows the
// plugin's `threads` topic, which every row's mark shares.
Rectangle {
    id: mark

    property var plugin
    property var thread
    property var threads: ({})
    readonly property var run: thread !== null ? (threads[thread.id] ?? null) : null
    readonly property string status: run?.status ?? ""
    readonly property int changes: run?.changes ?? 0
    readonly property color tone: {
        switch (status) {
        case "failed":
            return Theme.palette.color("error", "#ef4444");
        case "queued":
        case "running":
            return Theme.palette.color("info", "#3b82f6");
        case "proposed":
            return Theme.palette.color("warning", "#f59e0b");
        case "applied":
        case "done":
            return Theme.palette.color("success", "#22c55e");
        default:
            return Theme.palette.color("textMuted", "#a1a1aa");
        }
    }
    readonly property string label: {
        switch (status) {
        case "queued":
            return qsTr("Queued");
        case "running":
            return run?.kind === "work" ? qsTr("Working") : qsTr("Running");
        case "failed":
            return qsTr("Failed");
        case "proposed":
            if (changes === 0 && run?.health)
                return qsTr("Status update");
            return changes === 1 ? qsTr("1 change") : qsTr("%1 changes").arg(changes);
        case "applied":
            return qsTr("Applied");
        case "done":
            return qsTr("Done");
        default:
            return run?.kind === "work" ? qsTr("Task") : qsTr("Planner");
        }
    }
    property int watching: -1
    property string followed: ""

    // Follows `threads` on the MC of the thread, which a mark keeps while its row
    // shows another thread.
    function follow() {
        const environment = mark.thread?.environmentId ?? "";
        if (mark.watching >= 0 && environment === mark.followed)
            return;
        mark.plugin.unwatch(mark.watching);
        mark.followed = environment;
        mark.threads = {};
        mark.watching = mark.plugin.watch("threads", value => mark.threads = value ?? {}, environment || undefined);
    }

    objectName: "plannerRowMark"
    implicitWidth: text.implicitWidth + 10
    implicitHeight: text.implicitHeight + 2
    radius: height / 2
    color: Qt.alpha(tone, 0.14)
    border.color: Qt.alpha(tone, status === "proposed" ? 0.7 : 0.3)
    Accessible.role: Accessible.StaticText
    Accessible.name: qsTr("%1: %2").arg(run?.label ?? qsTr("Planner")).arg(label)
    onThreadChanged: follow()
    Component.onCompleted: follow()

    Text {
        id: text

        anchors.centerIn: parent
        text: mark.label
        color: mark.tone
        font.pixelSize: Math.round(10 * Theme.fontScale)
        font.weight: Font.Medium
    }
}
