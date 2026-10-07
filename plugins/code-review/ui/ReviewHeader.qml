import QtQuick
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// Above a review thread's conversation: the pull request it reviews, where the
// review is, its verdict, and publishing it. Follows the plugin's `threads` topic;
// the findings themselves are on the Reviews page.
Rectangle {
    id: header

    property var plugin
    property var thread
    property var threads: ({})
    readonly property var review: thread !== null ? (threads[thread.id] ?? null) : null
    readonly property string status: review?.status ?? ""
    readonly property string verdict: review?.verdict ?? ""
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
    readonly property color tone: verdict === "approve" ? Theme.palette.color("success", "#22c55e") : verdict === "request-changes" ? Theme.palette.color("warning", "#f59e0b") : muted
    property int watching: -1
    property string followed: ""
    property bool publishing: false
    // Why the last publish from here failed, until the review changes.
    property string refusal: ""

    // Follows `threads` on the MC of the thread, which a header keeps while the
    // user moves between review threads.
    function follow() {
        const environment = header.thread?.environmentId ?? "";
        if (header.watching >= 0 && environment === header.followed)
            return;
        header.plugin.unwatch(header.watching);
        header.followed = environment;
        header.threads = {};
        header.watching = header.plugin.watch("threads", value => header.threads = value ?? {}, environment || undefined);
    }

    function publish() {
        header.publishing = true;
        header.refusal = "";
        header.plugin.call("publish", { key: header.review.key }, (result, error) => {
            header.publishing = false;
            if (error)
                header.refusal = error;
        });
    }

    function statusText() {
        switch (header.status) {
        case "queued":
            return qsTr("Waiting for a free reviewer");
        case "running":
            return qsTr("The agent is reviewing");
        case "failed":
            return qsTr("Failed");
        case "waiting":
            return qsTr("Not published yet");
        case "kept":
            return qsTr("Kept in HAL-C2");
        case "published":
            return qsTr("Published");
        default:
            return "";
        }
    }

    function verdictText() {
        if (header.verdict === "approve")
            return qsTr("Approve");
        if (header.verdict === "request-changes")
            return qsTr("Request changes");
        if (header.verdict === "comment")
            return qsTr("Comment");
        return "";
    }

    objectName: "codeReviewHeader"
    visible: review !== null
    implicitHeight: review !== null ? column.implicitHeight + 16 : 0
    color: Theme.palette.color("surface", "#18181b")
    onStatusChanged: refusal = ""
    onThreadChanged: follow()
    Component.onCompleted: follow()

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1
        color: Theme.palette.color("border", "#27272a")
    }

    ColumnLayout {
        id: column

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 16
        anchors.rightMargin: 12
        spacing: 4

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Text {
                objectName: "codeReviewPullRequest"
                Layout.fillWidth: true
                text: header.review ? qsTr("Review of #%1 %2").arg(header.review.number).arg(header.review.title ?? "") : ""
                color: header.foreground
                elide: Text.ElideRight
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.Medium
            }

            Text {
                objectName: "codeReviewVerdict"
                visible: text.length > 0
                text: header.verdictText()
                color: header.tone
                font.pixelSize: Math.round(12 * Theme.fontScale)
                font.weight: Font.Medium
            }

            ShellButton {
                objectName: "codeReviewPublish"
                visible: header.status === "waiting" || header.status === "kept"
                primary: header.status === "waiting"
                enabled: !header.publishing
                text: header.publishing ? qsTr("Publishing…") : qsTr("Publish")
                onClicked: header.publish()
            }

            ShellButton {
                subtle: true
                visible: (header.review?.url ?? "").length > 0
                text: qsTr("Open on GitHub")
                onClicked: Qt.openUrlExternally(header.review.url)
            }
        }

        Text {
            Layout.fillWidth: true
            text: {
                const review = header.review;
                if (review === null)
                    return "";
                const where = review.headBranch && review.baseBranch ? qsTr("%1 into %2").arg(review.headBranch).arg(review.baseBranch) : "";
                return [review.repository, where, header.statusText()].filter(part => part && part.length > 0).join(" · ");
            }
            color: header.muted
            elide: Text.ElideRight
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        Text {
            objectName: "codeReviewProblem"
            Layout.fillWidth: true
            visible: text.length > 0
            text: header.refusal || header.review?.publishError || (header.status === "failed" ? header.review?.error ?? "" : "")
            color: header.errorColor
            wrapMode: Text.Wrap
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }
    }
}
