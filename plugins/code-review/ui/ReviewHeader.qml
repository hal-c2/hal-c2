import QtQuick
import QtQuick.Controls.Basic
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
    property bool stopping: false
    // Why the last publish from here failed, until the review changes.
    property string refusal: ""
    // What publishing would post (the MC's `preview`), shown for the user to confirm;
    // null while it is being read.
    property var preview: null
    property int previewAsk: 0
    readonly property string version: review?.version ?? ""

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

    // Reads what publishing would post, for the confirmation; an older answer, from
    // before the review changed, is dropped.
    function readPreview() {
        const ask = ++header.previewAsk;
        header.preview = null;
        header.plugin.call("preview", {
            key: header.review.key
        }, (result, error) => {
            if (ask !== header.previewAsk)
                return;
            if (error) {
                header.refusal = error;
                confirmation.close();
            } else {
                header.preview = result;
            }
        }, header.followed || undefined);
    }

    function askToPublish() {
        header.refusal = "";
        header.readPreview();
        confirmation.open();
    }

    // Publishes what the confirmation showed: its version and verdict, which the MC
    // refuses to post anything else under.
    function publish() {
        const shown = header.preview;
        confirmation.close();
        header.publishing = true;
        header.plugin.call("publish", {
            key: header.review.key,
            version: shown.version,
            verdict: shown.verdict
        }, (result, error) => {
            header.publishing = false;
            if (error)
                header.refusal = error;
        }, header.followed || undefined);
    }

    function stop() {
        header.stopping = true;
        header.refusal = "";
        header.plugin.call("stop", { key: header.review.key }, (result, error) => {
            header.stopping = false;
            if (error)
                header.refusal = error;
        }, header.thread?.environmentId || undefined);
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
        case "publishing":
            return qsTr("Publishing");
        case "kept":
            return qsTr("Kept in HAL-C2");
        case "published":
            return qsTr("Published");
        default:
            return "";
        }
    }

    function verdictText(verdict) {
        if (verdict === "approve")
            return qsTr("Approve");
        if (verdict === "request-changes")
            return qsTr("Request changes");
        if (verdict === "comment")
            return qsTr("Comment");
        return "";
    }

    objectName: "codeReviewHeader"
    visible: review !== null
    implicitHeight: review !== null ? column.implicitHeight + 16 : 0
    color: Theme.palette.color("surface", "#18181b")
    onStatusChanged: {
        refusal = "";
        if (status !== "waiting")
            confirmation.close();
    }
    // A review that changes while its confirmation is open is read again, so what is
    // confirmed is what is posted.
    onVersionChanged: {
        if (confirmation.opened)
            readPreview();
    }
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
                textFormat: Text.PlainText
                text: header.review ? qsTr("Review of #%1 %2").arg(header.review.number).arg(header.review.title ?? "") : ""
                color: header.foreground
                elide: Text.ElideRight
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.Medium
            }

            Text {
                objectName: "codeReviewVerdict"
                visible: text.length > 0
                text: header.verdictText(header.verdict)
                color: header.tone
                font.pixelSize: Math.round(12 * Theme.fontScale)
                font.weight: Font.Medium
            }

            ShellButton {
                objectName: "codeReviewPublish"
                visible: header.status === "waiting" || header.status === "publishing"
                primary: true
                enabled: header.status === "waiting" && !header.publishing
                text: enabled ? qsTr("Publish") : qsTr("Publishing…")
                onClicked: header.askToPublish()
            }

            ShellButton {
                objectName: "codeReviewStop"
                visible: header.status === "running"
                enabled: !header.stopping
                text: header.review?.sandboxed ? qsTr("Stop and delete the sandbox") : qsTr("Stop")
                onClicked: header.stop()
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
            textFormat: Text.PlainText
            text: {
                const review = header.review;
                if (review === null)
                    return "";
                const where = review.headBranch && review.baseBranch ? qsTr("%1 into %2").arg(review.headBranch).arg(review.baseBranch) : "";
                const sandbox = review.sandboxed ? qsTr("in a sandbox") : "";
                return [review.repository, where, header.statusText(), sandbox].filter(part => part && part.length > 0).join(" · ");
            }
            color: header.muted
            elide: Text.ElideRight
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        Text {
            objectName: "codeReviewProblem"
            Layout.fillWidth: true
            textFormat: Text.PlainText
            visible: text.length > 0
            text: header.refusal || header.review?.publishError || (header.status === "failed" ? header.review?.error ?? "" : "")
            color: header.errorColor
            wrapMode: Text.Wrap
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }
    }
    Popup {
        id: confirmation

        objectName: "codeReviewConfirmPublish"
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        // Takes the keyboard, so Escape closes it; focus goes back where it was.
        focus: true
        padding: 16
        width: Math.min(560, (parent?.width ?? 592) - 32)
        height: Math.min(implicitHeight, (parent?.height ?? 600) - 64)
        background: Rectangle {
            radius: Math.min(Theme.radius, 10)
            color: Theme.palette.color("surface", "#18181b")
            border.color: Theme.palette.color("border", "#27272a")
        }

        ColumnLayout {
            anchors.fill: parent
            spacing: 10

            Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: header.review ? qsTr("Publish the review of #%1 on GitHub?").arg(header.review.number) : ""
                color: header.foreground
                wrapMode: Text.Wrap
                font.pixelSize: Math.round(14 * Theme.fontScale)
                font.weight: Font.DemiBold
            }

            Text {
                objectName: "codeReviewConfirmVerdict"
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: header.preview ? qsTr("Posted as: %1").arg(header.verdictText(header.preview.verdict)) : qsTr("Reading what will be posted…")
                color: header.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }

            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: Math.min(posted.implicitHeight, 420)
                contentWidth: availableWidth
                visible: header.preview !== null

                ColumnLayout {
                    id: posted

                    width: parent.width
                    spacing: 8

                    Text {
                        objectName: "codeReviewConfirmBody"
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        text: header.preview?.body ?? ""
                        color: header.foreground
                        wrapMode: Text.Wrap
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }

                    Repeater {
                        model: header.preview?.comments ?? []

                        delegate: ColumnLayout {
                            required property var modelData
                            required property int index

                            objectName: "codeReviewConfirmComment:" + index
                            Layout.fillWidth: true
                            spacing: 2

                            Text {
                                Layout.fillWidth: true
                                textFormat: Text.PlainText
                                text: modelData.line ? "%1:%2".arg(modelData.path).arg(modelData.line) : modelData.path
                                color: header.muted
                                elide: Text.ElideMiddle
                                font.pixelSize: Math.round(11 * Theme.fontScale)
                            }

                            Text {
                                Layout.fillWidth: true
                                textFormat: Text.PlainText
                                text: modelData.body
                                color: header.foreground
                                wrapMode: Text.Wrap
                                font.pixelSize: Math.round(12 * Theme.fontScale)
                            }
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true

                Item {
                    Layout.fillWidth: true
                }

                ShellButton {
                    subtle: true
                    text: qsTr("Cancel")
                    onClicked: confirmation.close()
                }

                ShellButton {
                    objectName: "codeReviewConfirmPublishButton"
                    primary: true
                    enabled: header.preview !== null && header.status === "waiting"
                    text: qsTr("Publish")
                    onClicked: header.publish()
                }
            }
        }
    }
}
