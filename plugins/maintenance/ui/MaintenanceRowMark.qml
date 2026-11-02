import QtQuick
import HalC2.Shell

// Beside a maintenance thread's row in the thread list: where its run is. Follows
// the plugin's `threads` topic, which every row's mark shares.
Rectangle {
    id: mark

    property var plugin
    property var thread
    property var threads: ({})
    readonly property var run: thread !== null ? (threads[thread.id] ?? null) : null
    readonly property string status: run?.status ?? ""
    readonly property color tone: {
        if (status === "failed")
            return Theme.palette.color("error", "#ef4444");
        if (status === "running" || status === "publishing")
            return Theme.palette.color("info", "#3b82f6");
        if (status === "waiting")
            return Theme.palette.color("warning", "#f59e0b");
        if (status === "published")
            return Theme.palette.color("success", "#22c55e");
        return Theme.palette.color("textMuted", "#a1a1aa");
    }
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
    implicitWidth: text.implicitWidth + 10
    implicitHeight: text.implicitHeight + 2
    radius: height / 2
    color: Qt.alpha(tone, 0.14)
    border.color: Qt.alpha(tone, status === "waiting" ? 0.7 : 0.3)
    Accessible.role: Accessible.StaticText
    Accessible.name: qsTr("Maintenance: %1").arg(label)
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
