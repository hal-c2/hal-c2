import QtQuick
import HalC2.Bricks

// Beside a planner thread's row in the thread list: where its run is, or what it
// proposes. A thread whose run is gone, discarded or pruned, still came from the
// planner, so its mark stays with the kind's name ("Planner" or "Task"). Follows the
// plugin's `threads` topic, which every row's mark shares.
ShellBadge {
    id: mark

    property var plugin
    property var thread
    property var threads: ({})
    readonly property var run: thread !== null ? (threads[thread.id] ?? null) : null
    readonly property string status: run?.status ?? ""
    // The thread keeps its kind once its run is gone.
    readonly property bool work: (run?.kind ?? thread?.plugin?.kind) === "work"
    readonly property int changes: run?.changes ?? 0
    readonly property string label: {
        switch (status) {
        case "queued":
            return qsTr("Queued");
        case "running":
            return work ? qsTr("Working") : qsTr("Running");
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
            return work ? qsTr("Task") : qsTr("Planner");
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
    text: mark.label
    tone: {
        switch (status) {
        case "failed":
            return "error";
        case "queued":
        case "running":
            return "info";
        case "proposed":
            return "warning";
        case "applied":
        case "done":
            return "success";
        default:
            return "neutral";
        }
    }
    emphasised: status === "proposed"
    Accessible.role: Accessible.StaticText
    Accessible.name: qsTr("%1: %2").arg(run?.label ?? qsTr("Planner")).arg(label)
    onThreadChanged: follow()
    Component.onCompleted: follow()
}
