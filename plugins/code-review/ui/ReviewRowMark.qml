import QtQuick
import HalC2.Bricks

// Beside a review thread's row in the thread list: where its review is, and the
// verdict once the agent has one. Follows the plugin's `threads` topic, which every
// row's mark shares.
ShellBadge {
    id: mark

    property var plugin
    property var thread
    property var threads: ({})
    readonly property var review: thread !== null ? (threads[thread.id] ?? null) : null
    readonly property string status: review?.status ?? ""
    readonly property string verdict: review?.verdict ?? ""
    readonly property bool sandboxed: review?.sandboxed === true
    readonly property string label: {
        switch (status) {
        case "queued":
            return qsTr("Queued");
        case "running":
            return qsTr("Reviewing");
        case "failed":
            return qsTr("Failed");
        case "waiting":
        case "publishing":
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
    // A sandboxed review's mark says so; it is stopped from its header.
    text: mark.sandboxed ? qsTr("%1 · sandbox").arg(mark.label) : mark.label
    tone: {
        if (status === "failed")
            return "error";
        if (status === "running" || status === "queued" || status === "publishing")
            return "info";
        if (verdict === "approve")
            return "success";
        if (verdict === "request-changes")
            return "warning";
        return "neutral";
    }
    emphasised: status === "waiting"
    Accessible.role: Accessible.StaticText
    Accessible.name: (status === "waiting" ? qsTr("Review: %1, not published").arg(label) : qsTr("Review: %1").arg(label)) + (sandboxed ? qsTr(", in a sandbox") : "")
    onThreadChanged: follow()
    Component.onCompleted: follow()
}
