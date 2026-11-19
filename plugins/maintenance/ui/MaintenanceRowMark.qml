import QtQuick
import HalC2.Bricks

// Beside a maintenance thread's row in the thread list: where its run is. Follows
// the plugin's `threads` topic, which every row's mark shares.
ShellBadge {
    id: mark

    property var plugin
    property var thread
    property var threads: ({})
    readonly property var run: thread !== null ? (threads[thread.id] ?? null) : null
    readonly property string status: run?.status ?? ""
    readonly property string label: {
        switch (status) {
        case "running":
            return qsTr("Maintaining");
        case "waiting":
            return qsTr("Ready");
        case "publishing":
            return qsTr("Opening");
        case "kept":
            return qsTr("Kept");
        case "published":
            return qsTr("PR open");
        case "failed":
            return qsTr("Failed");
        case "cancelled":
            return qsTr("Cancelled");
        default:
            return qsTr("Maintenance");
        }
    }
    property int watching: -1
    property string followed: ""

    // Follows `threads` on the MC of the thread.
    function follow() {
        const environment = mark.thread?.environmentId ?? "";
        if (mark.watching >= 0 && environment === mark.followed)
            return;
        mark.plugin.unwatch(mark.watching);
        mark.followed = environment;
        mark.threads = {};
        mark.watching = mark.plugin.watch("threads", value => mark.threads = value ?? {}, environment || undefined);
    }

    objectName: "maintenanceRowMark"
    text: mark.label
    tone: {
        if (status === "failed")
            return "error";
        if (status === "running" || status === "publishing")
            return "info";
        if (status === "waiting")
            return "warning";
        if (status === "published")
            return "success";
        return "neutral";
    }
    emphasised: status === "waiting"
    Accessible.role: Accessible.StaticText
    Accessible.name: qsTr("Maintenance: %1").arg(label)
    onThreadChanged: follow()
    Component.onCompleted: follow()
}
