pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The Reviews page: the reviews of every MC that runs code-review, by state, and
// the one picked with its verdict, summary, checks and comments, and what can be done
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
    readonly property var order: ["running", "queued", "publishing", "waiting", "failed", "kept", "ready", "published"]
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
        case "publishing":
            return qsTr("Publishing");
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

    // Where another of the user's machines has the pull request's head.
    function elsewhereText(elsewhere) {
        const where = page.elsewhereWhere(elsewhere);
        return elsewhere.away ? qsTr("%1, out of reach").arg(where) : where;
    }

    function elsewhereWhere(elsewhere) {
        switch (elsewhere.status) {
        case "running":
            return qsTr("Reviewing on %1").arg(elsewhere.machine);
        case "queued":
            return qsTr("Queued on %1").arg(elsewhere.machine);
        case "failed":
            return qsTr("Failed on %1").arg(elsewhere.machine);
        default:
            return qsTr("Reviewed on %1").arg(elsewhere.machine);
        }
    }

    // A pull request nobody trusted is reviewed only at the commit the user approved.
    function gated(review) {
        return (review.untrusted ?? "").length > 0 && review.approved !== review.headSha && !["running", "queued", "publishing"].includes(review.status);
    }

    // Why a review is where it is, in a few words.
    function note(review) {
        if (review.elsewhere)
            return page.elsewhereText(review.elsewhere);
        if (review.status === "failed")
            return review.error ?? "";
        if (review.status === "waiting" && review.publishError)
            return qsTr("Publishing failed: %1").arg(review.publishError);
        if (review.status === "published" && review.publishNote)
            return review.publishNote;
        if (page.gated(review))
            return qsTr("%1 Approve it to review this commit.").arg(review.untrusted);
        // A review held for a machine out of reach has no time: it waits for the machine.
        if (review.limited && review.limited.until)
            return qsTr("Held back until %1: %2").arg(page.time(review.limited.until)).arg(review.limited.reason);
        if (review.limited)
            return qsTr("Held back: %1").arg(review.limited.reason);
        if (review.changed)
            return qsTr("Changed since its review");
        if (review.skipped)
            return qsTr("Skipped: %1").arg(review.skipped);
        return "";
    }

    function time(value) {
        return Format.dateTime(value);
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
                                    textFormat: Text.PlainText
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
                                textFormat: Text.PlainText
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
                                textFormat: Text.PlainText
                                text: page.note(row.modelData)
                                color: !row.modelData.elsewhere && (row.modelData.status === "failed" || row.modelData.publishError) ? page.errorColor : page.muted
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
                    // Only a waiting review can still be published; a kept one never is.
                    readonly property bool open: status === "waiting"
                    // The head commit shown when the user opened this review, or last took
                    // in: an approval vouches for it alone, so a push while the page is
                    // open is shown and has to be taken in before it can be approved.
                    property string seenId: ""
                    property string seenSha: ""
                    readonly property string headSha: review?.headSha ?? ""
                    readonly property bool moved: seenSha.length > 0 && headSha.length > 0 && seenSha !== headSha
                    readonly property bool approvable: review !== null && page.gated(review) && (!review.elsewhere || review.elsewhere.away === true) && seenSha.length > 0
                    // What publishing would post (the MC's `preview`), read when the user
                    // asks to publish and shown for them to confirm: the settings or
                    // GitHub may post the verdict as a comment. Null while it is read.
                    property bool confirming: false
                    property var preview: null
                    property int previewAsk: 0
                    readonly property string version: review?.version ?? ""

                    // Another review picked, or a head first known, is what is shown now.
                    function see() {
                        const id = review?.id ?? "";
                        if (id !== seenId || seenSha.length === 0) {
                            if (id !== seenId)
                                cancelPublish();
                            seenId = id;
                            seenSha = review?.headSha ?? "";
                        }
                    }

                    // Reads what publishing would post; an older answer, from before the
                    // review changed, is dropped.
                    function readPreview() {
                        const ask = ++previewAsk;
                        preview = null;
                        page.refusal = "";
                        page.plugin.call("preview", {
                            key: review.key
                        }, (result, error) => {
                            if (ask !== findings.previewAsk)
                                return;
                            if (error) {
                                page.refusal = error;
                                findings.cancelPublish();
                            } else {
                                findings.preview = result;
                            }
                        }, review.environment);
                    }

                    function cancelPublish() {
                        ++previewAsk;
                        confirming = false;
                        preview = null;
                    }

                    // Publishes what was shown: the findings' version and the verdict of the
                    // post, which the MC refuses to post anything else under.
                    function publish() {
                        const shown = preview;
                        cancelPublish();
                        page.ask("publish", {
                            key: review.key,
                            version: shown.version,
                            verdict: shown.verdict
                        }, review.environment);
                    }

                    onReviewChanged: see()
                    onVersionChanged: if (confirming)
                        readPreview()
                    onOpenChanged: if (!open)
                        cancelPublish()
                    Component.onCompleted: see()

                    x: 20
                    y: 16
                    width: detail.width - 40
                    visible: review !== null
                    spacing: 10

                    Text {
                        objectName: "codeReviewTitle"
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        text: findings.review ? "#" + findings.review.number + "  " + (findings.review.title ?? "") : ""
                        color: page.foreground
                        wrapMode: Text.Wrap
                        font.pixelSize: Math.round(16 * Theme.fontScale)
                        font.weight: Font.DemiBold
                    }

                    Text {
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
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
                            visible: findings.open && !findings.confirming
                            primary: true
                            enabled: page.busy === 0
                            text: qsTr("Publish to GitHub")
                            onClicked: {
                                findings.confirming = true;
                                findings.readPreview();
                            }
                        }

                        // How the post goes, for the user to confirm before anything is posted.
                        Text {
                            objectName: "codeReviewPublishVerdict"
                            visible: findings.open && findings.confirming
                            height: approve.height
                            verticalAlignment: Text.AlignVCenter
                            textFormat: Text.PlainText
                            text: findings.preview ? qsTr("Posted as: %1").arg(page.verdictText(findings.preview.verdict)) : qsTr("Reading what will be posted…")
                            color: page.foreground
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }

                        ShellButton {
                            objectName: "codeReviewPublishConfirm"
                            visible: findings.open && findings.confirming
                            primary: true
                            // The post read is of the findings shown here.
                            enabled: page.busy === 0 && findings.preview !== null && findings.preview.version === findings.version
                            text: qsTr("Publish")
                            onClicked: findings.publish()
                        }

                        ShellButton {
                            objectName: "codeReviewPublishCancel"
                            visible: findings.open && findings.confirming
                            subtle: true
                            text: qsTr("Cancel")
                            onClicked: findings.cancelPublish()
                        }

                        ShellButton {
                            objectName: "codeReviewRetry"
                            // Another machine reviews this head; a review here would be a second one,
                            // unless that machine is out of reach and may not come back.
                            visible: findings.review !== null && (!findings.review.elsewhere || findings.review.elsewhere.away === true) && !["running", "queued", "publishing"].includes(findings.status) && !page.gated(findings.review)
                            primary: findings.status === "ready" || findings.status === "failed"
                            enabled: page.busy === 0
                            text: findings.status === "ready" ? qsTr("Review") : findings.status === "failed" ? qsTr("Try again") : qsTr("Review again")
                            onClicked: page.ask("retry", { key: findings.review.key }, findings.review.environment)
                        }

                        // The commit an approval vouches for, and a push since it was shown.
                        Text {
                            objectName: "codeReviewApproveCommit"
                            visible: findings.approvable
                            height: approve.height
                            verticalAlignment: Text.AlignVCenter
                            textFormat: Text.PlainText
                            text: findings.moved ? qsTr("Pushed since you opened it: now at %1, not %2").arg(findings.headSha.slice(0, 7)).arg(findings.seenSha.slice(0, 7)) : qsTr("At commit %1").arg(findings.seenSha.slice(0, 7))
                            color: findings.moved ? page.warningColor : page.muted
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }

                        // The user vouches for the commit shown, and only that one: a push
                        // needs another approval, and one while the page is open is taken
                        // in first rather than approved unseen.
                        ShellButton {
                            id: approve

                            objectName: "codeReviewApprove"
                            visible: findings.approvable
                            primary: true
                            enabled: page.busy === 0
                            text: findings.moved ? qsTr("Show the new commit") : qsTr("Approve and review")
                            onClicked: {
                                if (findings.moved)
                                    findings.seenSha = findings.headSha;
                                else
                                    page.ask("approve", { key: findings.review.key, headSha: findings.seenSha }, findings.review.environment);
                            }
                        }

                        // Any approval kept can be taken back, whichever commit it is of.
                        ShellButton {
                            objectName: "codeReviewUnapprove"
                            visible: findings.review !== null && (findings.review.untrusted ?? "").length > 0 && (findings.review.approved ?? "").length > 0 && !["running", "publishing"].includes(findings.status)
                            subtle: true
                            enabled: page.busy === 0
                            text: qsTr("Withdraw approval")
                            onClicked: page.ask("unapprove", { key: findings.review.key }, findings.review.environment)
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
                            visible: findings.review !== null && findings.status !== "running" && findings.status !== "publishing"
                            enabled: page.busy === 0
                            text: qsTr("Discard")
                            onClicked: page.ask("discard", { key: findings.review.key }, findings.review.environment)
                        }
                    }

                    Text {
                        objectName: "codeReviewProblem"
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        visible: text.length > 0
                        text: findings.review ? page.note(findings.review) : ""
                        color: !findings.review?.elsewhere && (findings.status === "failed" || findings.review?.publishError) ? page.errorColor : page.muted
                        wrapMode: Text.Wrap
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }

                    // A check the machine kept the agent from running is the machine's
                    // to fix, not a finding: it is shown apart from the verdict.
                    Rectangle {
                        objectName: "codeReviewBlocked"
                        Layout.fillWidth: true
                        visible: (findings.review?.validation?.blocked ?? []).length > 0
                        implicitHeight: blockedText.implicitHeight + 16
                        radius: Math.min(Theme.radius, 8)
                        color: "transparent"
                        border.color: page.warningColor

                        Text {
                            id: blockedText

                            objectName: "codeReviewBlockedText"
                            // The agent's words, never markup.
                            textFormat: Text.PlainText
                            anchors.fill: parent
                            anchors.margins: 8
                            text: qsTr("The agent could not run these on the MC's machine. Fix them there and review again:") + "\n" + (findings.review?.validation?.blocked ?? []).map(entry => "• " + entry.check + ": " + entry.error).join("\n")
                            color: page.warningColor
                            wrapMode: Text.Wrap
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }
                    }

                    Text {
                        objectName: "codeReviewHeadline"
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        visible: text.length > 0
                        text: findings.review?.headline ?? ""
                        color: page.foreground
                        wrapMode: Text.Wrap
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                        font.weight: Font.DemiBold
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

                    Repeater {
                        model: [
                            { name: "notRun", title: qsTr("Not run"), lines: (findings.review?.validation?.notRun ?? []).map(entry => entry.check + ": " + entry.reason) },
                            { name: "ran", title: qsTr("Ran"), lines: (findings.review?.validation?.ran ?? []).map(entry => entry.command + ": " + entry.result) }
                        ].filter(section => section.lines.length > 0)

                        delegate: ColumnLayout {
                            id: section

                            required property var modelData

                            objectName: "codeReviewValidation:" + modelData.name
                            Layout.fillWidth: true
                            spacing: 4

                            Text {
                                text: section.modelData.title
                                color: page.muted
                                font.pixelSize: Math.round(11 * Theme.fontScale)
                                font.weight: Font.Medium
                                font.capitalization: Font.AllUppercase
                            }

                            Text {
                                objectName: "codeReviewValidationLines:" + section.modelData.name
                                textFormat: Text.PlainText
                                Layout.fillWidth: true
                                text: section.modelData.lines.map(line => "• " + line).join("\n")
                                color: page.foreground
                                wrapMode: Text.Wrap
                                font.pixelSize: Math.round(12 * Theme.fontScale)
                            }
                        }
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
                                        textFormat: Text.PlainText
                                        text: comment.modelData.path + ":" + comment.modelData.line + (comment.modelData.side === "old" ? " " + qsTr("(removed)") : "") + (comment.modelData.severity ? " · " + (({ high: "🔴 High", medium: "🟡 Medium", low: "🔵 Low", blocking: "🔴 High", suggestion: "🟡 Medium", nit: "🔵 Low" })[comment.modelData.severity] ?? comment.modelData.severity) : "")
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
