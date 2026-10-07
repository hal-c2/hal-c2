import QtQuick
import HalC2.Shell

// Beside a review thread's row in the thread list: where its review is, and the
// verdict once the agent has one. Follows the plugin's `threads` topic, which every
// row's mark shares.
Rectangle {
    id: mark

    property var plugin
    property var thread
    property var threads: ({})
    readonly property var review: thread !== null ? (threads[thread.id] ?? null) : null
    readonly property string status: review?.status ?? ""
    readonly property string verdict: review?.verdict ?? ""
    readonly property color tone: {
        if (status === "failed")
            return Theme.palette.color("error", "#ef4444");
        if (status === "running" || status === "queued")
            return Theme.palette.color("info", "#3b82f6");
        if (verdict === "approve")
            return Theme.palette.color("success", "#22c55e");
        if (verdict === "request-changes")
            return Theme.palette.color("warning", "#f59e0b");
        return Theme.palette.color("textMuted", "#a1a1aa");
    }
    readonly property string label: {
        switch (status) {
        case "queued":
            return qsTr("Queued");
        case "running":
            return qsTr("Reviewing");
        case "failed":
            return qsTr("Failed");
        case "waiting":
        case "kept":
        case "published":
            return verdict === "approve" ? qsTr("Approve") : verdict === "request-changes" ? qsTr("Changes") : qsTr("Comment");
        default:
            return qsTr("Review");
        }
    }
    property int watching: -1
    property string followed: ""

    // Follows `threads` on the MC of the thread, which a header keeps while the
    // user moves between review threads.
    function follow() {
        const environment = mark.thread?.environmentId ?? "";
        if (mark.watching >= 0 && environment === mark.followed)
            return;
        mark.plugin.unwatch(mark.watching);
        mark.followed = environment;
        mark.threads = {};
        mark.watching = mark.plugin.watch("threads", value => mark.threads = value ?? {}, environment || undefined);
    }

    objectName: "codeReviewRowMark"
    implicitWidth: text.implicitWidth + 10
    implicitHeight: text.implicitHeight + 2
    radius: height / 2
    color: Qt.alpha(tone, 0.14)
    border.color: Qt.alpha(tone, status === "waiting" ? 0.7 : 0.3)
    Accessible.role: Accessible.StaticText
    Accessible.name: status === "waiting" ? qsTr("Review: %1, not published").arg(label) : qsTr("Review: %1").arg(label)
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
