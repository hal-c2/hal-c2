pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The Reviews page: the reviews of every MC that runs code-review, by state, and
// the one picked with its verdict, summary and comments, and what can be done
// with it. Follows each MC's `reviews` topic.
Item {
    id: page

    property var plugin
    // environment → the last value of its `reviews` topic.
    property var byEnvironment: ({})
    // environment → its watch.
    property var watches: ({})
    readonly property var reviews: {
        const all = [];
        for (const environment of plugin.environments) {
            for (const review of byEnvironment[environment]?.reviews ?? [])
                all.push(Object.assign({ environment: environment, id: environment + "|" + review.key }, review));
        }
        return all.sort((a, b) => page.order.indexOf(a.status) - page.order.indexOf(b.status));
    }
    readonly property var order: ["running", "queued", "waiting", "failed", "kept", "ready", "published"]
    property string selected: ""
    readonly property var review: reviews.find(review => review.id === selected) ?? null
    // Why the last action from this page failed, until the next one.
    property string refusal: ""
    property int busy: 0
    readonly property bool several: plugin.environments.length > 1
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color border: Theme.palette.color("border", "#27272a")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
    readonly property color warningColor: Theme.palette.color("warning", "#f59e0b")

    function follow() {
        const watches = {};
        for (const environment of page.plugin.environments) {
            watches[environment] = page.watches[environment] ?? page.plugin.watch("reviews", value => {
                const next = Object.assign({}, page.byEnvironment);
                next[environment] = value;
                page.byEnvironment = next;
            }, environment);
        }
        for (const environment of Object.keys(page.watches)) {
            if (watches[environment] === undefined)
                page.plugin.unwatch(page.watches[environment]);
        }
        page.watches = watches;
    }

    // Calls the MC part of `environment`; what it refuses is shown above the list.
    function ask(method, input, environment) {
        page.refusal = "";
        page.busy += 1;
        page.plugin.call(method, input, (result, error) => {
            page.busy -= 1;
            if (error)
                page.refusal = error;
        }, environment);
    }

    function environmentLabel(environment) {
        const known = (Shell.state.mcPlugins?.environments ?? []).find(each => each.id === environment);
        return known?.label ?? environment;
    }

    function statusText(status) {
        switch (status) {
        case "running":
            return qsTr("Reviewing");
        case "queued":
            return qsTr("Queued");
        case "waiting":
            return qsTr("Waiting to publish");
        case "failed":
            return qsTr("Failed");
        case "kept":
            return qsTr("Kept in HAL-C2");
        case "ready":
            return qsTr("Not reviewed");
        case "published":
            return qsTr("Published");
        default:
            return status;
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

    function verdictColor(verdict) {
        if (verdict === "approve")
            return Theme.palette.color("success", "#22c55e");
        if (verdict === "request-changes")
            return page.warningColor;
        return page.muted;
    }

    // Why a review is where it is, in a few words.
    function note(review) {
        if (review.status === "failed")
            return review.error ?? "";
        if (review.status === "waiting" && review.publishError)
            return qsTr("Publishing failed: %1").arg(review.publishError);
        if (review.changed)
            return qsTr("Changed since its review");
        if (review.skipped)
            return qsTr("Skipped: %1").arg(review.skipped);
        return "";
    }

    function time(value) {
        return value ? Qt.formatDateTime(new Date(value), Qt.locale().dateTimeFormat(Locale.ShortFormat)) : "";
    }

    objectName: "codeReviewPage"
    implicitWidth: 900
    implicitHeight: 600
    onReviewsChanged: if (review === null && reviews.length > 0)
        selected = reviews[0].id
    Component.onCompleted: follow()

    Connections {
        target: page.plugin

        function onEnvironmentsChanged() {
            page.follow();
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // What is watched, how the watch went, and starting a review by hand.
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: bar.implicitHeight + 20
            color: Theme.palette.color("surface", "#18181b")

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: page.border
            }

            ColumnLayout {
                id: bar

                anchors.fill: parent
                anchors.margins: 10
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 6

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Text {
                        objectName: "codeReviewWatching"
                        Layout.fillWidth: true
                        text: {
                            const parts = [];
                            for (const environment of page.plugin.environments) {
                                const state = page.byEnvironment[environment];
                                if (!state)
                                    continue;
                                const watching = state.watching.length > 0 ? state.watching.join(", ") : qsTr("no repositories");
                                const mode = state.activation === "automatic" ? qsTr("every new pull request") : qsTr("when asked");
                                const line = qsTr("Watching %1, %2").arg(watching).arg(mode);
                                parts.push(page.several ? page.environmentLabel(environment) + ": " + line : line);
                            }
                            return parts.join("  ·  ");
                        }
                        color: page.muted
                        elide: Text.ElideRight
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }

                    ShellComboBox {
                        id: startRepository

                        readonly property var choices: {
                            const all = [];
                            for (const environment of page.plugin.environments) {
                                for (const repository of page.byEnvironment[environment]?.watching ?? [])
                                    all.push({ environment: environment, repository: repository, label: page.several ? repository + " (" + page.environmentLabel(environment) + ")" : repository });
                            }
                            return all;
                        }

                        objectName: "codeReviewStartRepository"
                        visible: choices.length > 0
                        outline: true
                        implicitWidth: 200
                        model: choices.map(choice => choice.label)
                        Accessible.name: qsTr("Repository to review")
                    }

                    ShellTextField {
                        id: startNumber

                        objectName: "codeReviewStartNumber"
                        visible: startRepository.visible
                        implicitWidth: 90
                        placeholderText: qsTr("PR #")
                        inputMethodHints: Qt.ImhDigitsOnly
                        validator: IntValidator {
                            bottom: 1
                        }
                        Accessible.name: qsTr("Pull request number")
                        onAccepted: startButton.clicked()
                    }

                    ShellButton {
                        id: startButton

                        objectName: "codeReviewStart"
                        visible: startRepository.visible
                        enabled: startNumber.acceptableInput
                        text: qsTr("Review")
                        onClicked: {
                            const choice = startRepository.choices[Math.max(0, startRepository.currentIndex)];
                            const number = Number(startNumber.text);
                            page.selected = choice.environment + "|" + choice.repository + "#" + number;
                            page.ask("start", { repository: choice.repository, number: number }, choice.environment);
                            startNumber.text = "";
                        }
                    }

                    ShellButton {
                        objectName: "codeReviewRefresh"
                        subtle: true
                        enabled: page.busy === 0
                        text: qsTr("Look now")
                        onClicked: {
                            for (const environment of page.plugin.environments)
                                page.ask("refresh", {}, environment);
                        }
                    }
                }

                Repeater {
                    model: page.plugin.environments

                    delegate: Text {
                        required property string modelData
                        readonly property var state: page.byEnvironment[modelData] ?? null
                        readonly property string problem: {
                            if (state === null)
                                return "";
                            if (state.problem)
                                return state.problem;
                            if (state.unwatched.length > 0)
                                return qsTr("No project on this MC has the remote of %1, so it is not watched.").arg(state.unwatched.join(", "));
                            return "";
                        }

                        Layout.fillWidth: true
                        visible: problem.length > 0
                        text: page.several ? page.environmentLabel(modelData) + ": " + problem : problem
                        color: page.warningColor
                        wrapMode: Text.Wrap
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }
                }

                Text {
                    objectName: "codeReviewRefusal"
                    Layout.fillWidth: true
                    visible: page.refusal.length > 0
                    text: page.refusal
                    color: page.errorColor
                    wrapMode: Text.Wrap
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            ListView {
                id: list

                objectName: "codeReviewList"
                Layout.preferredWidth: Math.min(380, page.width * 0.4)
                Layout.fillHeight: true
                clip: true
                model: page.reviews
                currentIndex: page.reviews.findIndex(review => review.id === page.selected)
                keyNavigationEnabled: true
                boundsBehavior: Flickable.StopAtBounds
                onCurrentIndexChanged: if (currentIndex >= 0 && activeFocus)
                    page.selected = page.reviews[currentIndex].id

                ScrollBar.vertical: ScrollBar {}

                delegate: Column {
                    id: entry

                    required property var modelData
                    required property int index

                    width: ListView.view.width

                    // The first review of a state names it.
                    Text {
                        width: entry.width
                        visible: entry.index === 0 || page.reviews[entry.index - 1].status !== entry.modelData.status
                        leftPadding: 16
                        topPadding: entry.index > 0 ? 14 : 10
                        bottomPadding: 4
                        text: page.statusText(entry.modelData.status)
                        color: page.muted
                        font.pixelSize: Math.round(11 * Theme.fontScale)
                        font.weight: Font.Medium
                        font.capitalization: Font.AllUppercase
                    }

                    ItemDelegate {
                        id: row

                        readonly property var modelData: entry.modelData
                        readonly property int index: entry.index

                        objectName: "codeReview:" + modelData.key
                        width: entry.width
                        leftPadding: 16
                        rightPadding: 12
                        topPadding: 6
                        bottomPadding: 6
                        highlighted: modelData.id === page.selected
                        Accessible.name: qsTr("#%1 %2, %3").arg(modelData.number).arg(modelData.title).arg(page.statusText(modelData.status))
                        onClicked: {
                            page.selected = modelData.id;
                            list.currentIndex = index;
                            list.forceActiveFocus();
                        }

                        background: Rectangle {
                            color: row.highlighted ? Theme.palette.color("sidebarRowSelected", "#27272a") : row.hovered ? Theme.palette.color("sidebarRowHover", "#1f1f23") : "transparent"
                        }

                        contentItem: ColumnLayout {
                            spacing: 2

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 6

                                Text {
                                    Layout.fillWidth: true
                                    text: "#" + row.modelData.number + "  " + (row.modelData.title ?? "")
                                    color: page.foreground
                                    elide: Text.ElideRight
                                    font.pixelSize: Math.round(13 * Theme.fontScale)
                                }

                                Text {
                                    visible: text.length > 0
                                    text: page.verdictText(row.modelData.verdict)
                                    color: page.verdictColor(row.modelData.verdict)
                                    font.pixelSize: Math.round(11 * Theme.fontScale)
                                    font.weight: Font.Medium
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                text: {
                                    const parts = [row.modelData.repository, row.modelData.author];
                                    if (page.several)
                                        parts.push(page.environmentLabel(row.modelData.environment));
                                    return parts.filter(part => part).join(" · ");
                                }
                                color: page.muted
                                elide: Text.ElideRight
                                font.pixelSize: Math.round(11 * Theme.fontScale)
                            }

                            Text {
                                Layout.fillWidth: true
                                visible: text.length > 0
                                text: page.note(row.modelData)
                                color: row.modelData.status === "failed" || row.modelData.publishError ? page.errorColor : page.muted
                                elide: Text.ElideRight
                                font.pixelSize: Math.round(11 * Theme.fontScale)
                            }
                        }
                    }
                }

                Text {
                    anchors.centerIn: parent
                    width: parent.width - 48
                    visible: page.reviews.length === 0
                    text: qsTr("No reviews yet. Pick repositories to watch in the plugin's settings, or start a review above.")
                    color: page.muted
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                }
            }

            Rectangle {
                Layout.preferredWidth: 1
                Layout.fillHeight: true
                color: page.border
            }

            // The review picked in the list.
            Flickable {
                id: detail

                objectName: "codeReviewDetail"
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentHeight: findings.implicitHeight + 32
                boundsBehavior: Flickable.StopAtBounds

                ScrollBar.vertical: ScrollBar {}

                ColumnLayout {
                    id: findings

                    readonly property var review: page.review
                    readonly property string status: review?.status ?? ""
                    readonly property bool open: status === "waiting" || status === "kept"

                    x: 20
                    y: 16
                    width: detail.width - 40
                    visible: review !== null
                    spacing: 10

                    Text {
                        objectName: "codeReviewTitle"
                        Layout.fillWidth: true
                        text: findings.review ? "#" + findings.review.number + "  " + (findings.review.title ?? "") : ""
                        color: page.foreground
                        wrapMode: Text.Wrap
                        font.pixelSize: Math.round(16 * Theme.fontScale)
                        font.weight: Font.DemiBold
                    }

                    Text {
                        Layout.fillWidth: true
                        text: {
                            const review = findings.review;
                            if (!review)
                                return "";
                            const where = review.headBranch && review.baseBranch ? qsTr("%1 into %2").arg(review.headBranch).arg(review.baseBranch) : "";
                            const by = review.author ? qsTr("by %1").arg(review.author) : "";
                            return [review.repository, where, by].filter(part => part.length > 0).join(" · ");
                        }
                        color: page.muted
                        wrapMode: Text.Wrap
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        Text {
                            objectName: "codeReviewStatus"
                            text: {
                                const review = findings.review;
                                if (!review)
                                    return "";
                                if (review.status === "published")
                                    return qsTr("Published %1").arg(page.time(review.publishedAt));
                                if (review.status === "running" || review.status === "queued")
                                    return page.statusText(review.status) + (review.trigger ? " · " + qsTr("asked by %1").arg(review.trigger) : "");
                                return page.statusText(review.status);
                            }
                            color: page.foreground
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }

                        Text {
                            objectName: "codeReviewVerdict"
                            visible: text.length > 0
                            text: page.verdictText(findings.review?.verdict)
                            color: page.verdictColor(findings.review?.verdict)
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            font.weight: Font.DemiBold
                        }

                        Item {
                            Layout.fillWidth: true
                        }
                    }

                    Flow {
                        Layout.fillWidth: true
                        spacing: 8

                        ShellButton {
                            objectName: "codeReviewPublish"
                            visible: findings.open
                            primary: findings.status === "waiting"
                            enabled: page.busy === 0
                            text: qsTr("Publish to GitHub")
                            onClicked: page.ask("publish", { key: findings.review.key }, findings.review.environment)
                        }

                        ShellButton {
                            objectName: "codeReviewRetry"
                            visible: findings.review !== null && findings.status !== "running" && findings.status !== "queued"
                            primary: findings.status === "ready" || findings.status === "failed"
                            enabled: page.busy === 0
                            text: findings.status === "ready" ? qsTr("Review") : findings.status === "failed" ? qsTr("Try again") : qsTr("Review again")
                            onClicked: page.ask("retry", { key: findings.review.key }, findings.review.environment)
                        }

                        ShellButton {
                            objectName: "codeReviewOpenThread"
                            visible: (findings.review?.threadId ?? "").length > 0
                            text: qsTr("Open thread")
                            onClicked: page.plugin.openThread(findings.review.threadId, findings.review.environment)
                        }

                        ShellButton {
                            subtle: true
                            visible: (findings.review?.url ?? "").length > 0
                            text: qsTr("Open on GitHub")
                            onClicked: Qt.openUrlExternally(findings.review.url)
                        }

                        ShellButton {
                            objectName: "codeReviewDiscard"
                            subtle: true
                            visible: findings.review !== null && findings.status !== "running"
                            enabled: page.busy === 0
                            text: qsTr("Discard")
                            onClicked: page.ask("discard", { key: findings.review.key }, findings.review.environment)
                        }
                    }

                    Text {
                        objectName: "codeReviewProblem"
                        Layout.fillWidth: true
                        visible: text.length > 0
                        text: findings.review ? page.note(findings.review) : ""
                        color: findings.status === "failed" || findings.review?.publishError ? page.errorColor : page.muted
                        wrapMode: Text.Wrap
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }

                    TextEdit {
                        objectName: "codeReviewSummary"
                        Layout.fillWidth: true
                        visible: (findings.review?.summary ?? "").length > 0
                        readOnly: true
                        selectByMouse: true
                        textFormat: TextEdit.MarkdownText
                        text: findings.review?.summary ?? ""
                        color: page.foreground
                        wrapMode: TextEdit.Wrap
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                        onLinkActivated: link => Qt.openUrlExternally(link)
                    }

                    Text {
                        visible: (findings.review?.comments ?? []).length > 0
                        text: findings.open ? qsTr("Comments, posted on their lines when you publish") : qsTr("Comments")
                        color: page.muted
                        font.pixelSize: Math.round(11 * Theme.fontScale)
                        font.weight: Font.Medium
                        font.capitalization: Font.AllUppercase
                    }

                    Repeater {
                        model: findings.review?.comments ?? []

                        delegate: Rectangle {
                            id: comment

                            required property var modelData
                            readonly property bool dismissed: modelData.dismissed === true

                            objectName: "codeReviewComment:" + modelData.id
                            Layout.fillWidth: true
                            implicitHeight: commentColumn.implicitHeight + 16
                            radius: Math.min(Theme.radius, 8)
                            color: Theme.palette.color("surfaceRaised", "#1f1f23")
                            border.color: page.border
                            opacity: dismissed ? 0.55 : 1

                            ColumnLayout {
                                id: commentColumn

                                anchors.fill: parent
                                anchors.margins: 8
                                anchors.leftMargin: 12
                                spacing: 4

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8

                                    Text {
                                        Layout.fillWidth: true
                                        text: comment.modelData.path + ":" + comment.modelData.line + (comment.modelData.side === "old" ? " " + qsTr("(removed)") : "")
                                        color: page.muted
                                        elide: Text.ElideMiddle
                                        font.family: Theme.fontMono
                                        font.pixelSize: Math.round(12 * Theme.fontScale)
                                        font.strikeout: comment.dismissed
                                    }

                                    ShellButton {
                                        objectName: "codeReviewDismiss"
                                        visible: findings.open
                                        subtle: true
                                        enabled: page.busy === 0
                                        text: comment.dismissed ? qsTr("Keep") : qsTr("Dismiss")
                                        onClicked: page.ask("dismiss", { key: findings.review.key, commentId: comment.modelData.id, dismissed: !comment.dismissed }, findings.review.environment)
                                    }
                                }

                                TextEdit {
                                    Layout.fillWidth: true
                                    readOnly: true
                                    selectByMouse: true
                                    textFormat: TextEdit.MarkdownText
                                    text: comment.modelData.body
                                    color: page.foreground
                                    wrapMode: TextEdit.Wrap
                                    font.pixelSize: Math.round(13 * Theme.fontScale)
                                    onLinkActivated: link => Qt.openUrlExternally(link)
                                }
                            }
                        }
                    }
                }

                Text {
                    anchors.centerIn: parent
                    visible: page.review === null && page.reviews.length > 0
                    text: qsTr("Pick a review")
                    color: page.muted
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                }
            }
        }
    }
}
