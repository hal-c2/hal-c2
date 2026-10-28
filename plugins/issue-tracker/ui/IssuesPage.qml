pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The Issues page: the open GitHub issues of the repositories the tracker
// follows, and what its triage agents propose for them. From an issue, an
// agent drafts a follow-up question or a summary, or starts implementing it in
// a thread of its own. Nothing an agent proposes reaches GitHub until it is
// applied here. Follows the `tracker` topic of each MC that runs the tracker,
// one MC at a time.
Item {
    id: page

    property var plugin
    // environment → the last value of its `tracker` topic.
    property var byEnvironment: ({})
    // environment → its watch.
    property var watches: ({})
    property string environment: ""
    readonly property var tracker: byEnvironment[environment] ?? null
    // "" follows every repository in the list.
    property string repository: ""
    readonly property var repositories: tracker?.repositories ?? []
    readonly property var issues: (tracker?.issues ?? []).filter(issue => repository === "" || issue.repository === repository)
    property string selected: ""
    readonly property var issue: issues.find(each => each.key === selected) ?? null
    // The picked issue with its body, read when it is opened.
    property var opened: null
    // "issues" or "proposals".
    property string view: "issues"
    property string refusal: ""
    readonly property var runs: tracker?.runs ?? []
    readonly property int proposed: runs.filter(run => run.status === "proposed").length
    // "implement:<key>" → the thread last started for it.
    readonly property var threads: tracker?.threads ?? ({})
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color border: Theme.palette.color("border", "#27272a")
    readonly property color warningColor: Theme.palette.color("warning", "#f59e0b")
    readonly property color successColor: Theme.palette.color("success", "#22c55e")

    function follow() {
        const watches = {};
        for (const environment of page.plugin.environments) {
            watches[environment] = page.watches[environment] ?? page.plugin.watch("tracker", value => {
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
        if (!page.plugin.environments.includes(page.environment))
            page.environment = page.plugin.environments[0] ?? "";
    }

    function start(method, input) {
        page.refusal = "";
        page.plugin.call(method, input, (result, error) => {
            if (error)
                page.refusal = error;
        }, page.environment);
    }

    // Reads the picked issue in full; an answer for an issue no longer picked
    // is dropped. Looked up by key, not through the `issue` binding, which has
    // not caught up when `selected` first changes.
    function openIssue() {
        page.opened = null;
        const issue = page.issues.find(each => each.key === page.selected) ?? null;
        if (!issue)
            return;
        page.plugin.call("issue", {
            repository: issue.repository,
            number: issue.number
        }, (result, error) => {
            if (page.selected !== issue.key)
                return;
            if (error)
                page.refusal = error;
            else
                page.opened = result;
        }, page.environment);
    }

    function openThread(thread) {
        page.plugin.openThread(thread.threadId ?? thread, page.environment);
    }

    // How a thread's last turn went.
    function threadStatus(thread) {
        switch (thread.status) {
        case "running":
            return qsTr("running");
        case "completed":
            return qsTr("done");
        case "failed":
            return qsTr("failed");
        case "interrupted":
            return qsTr("stopped");
        default:
            return thread.status;
        }
    }

    function runStatus(run) {
        switch (run.status) {
        case "running":
            return qsTr("Running");
        case "proposed":
            return qsTr("Waiting for you");
        case "applying":
            return qsTr("Applying…");
        case "applied":
            return qsTr("Applied");
        case "done":
            return qsTr("Nothing to apply");
        case "discarded":
            return qsTr("Dismissed");
        case "failed":
            return qsTr("Failed");
        default:
            return run.status;
        }
    }

    function runTitle(run) {
        if (run.title)
            return run.title;
        switch (run.action) {
        case "prioritise":
            return qsTr("Prioritise %1").arg(run.repository);
        case "followUp":
            return qsTr("Follow up on %1#%2").arg(run.repository).arg(run.number);
        case "summarise":
            return qsTr("Summarise %1#%2").arg(run.repository).arg(run.number);
        default:
            return run.action;
        }
    }

    function environmentLabel(environment) {
        const known = (Shell.state.mcPlugins?.environments ?? []).find(each => each.id === environment);
        return known?.label ?? environment;
    }

    function date(value) {
        return value ? Qt.formatDate(new Date(value), Qt.locale().dateFormat(Locale.ShortFormat)) : "";
    }

    function issueMeta(issue) {
        const parts = [];
        if (issue.author)
            parts.push(issue.author);
        if (issue.labels.length > 0)
            parts.push(issue.labels.join(", "));
        if (issue.updatedAt)
            parts.push(qsTr("updated %1").arg(date(issue.updatedAt)));
        return parts.join(" · ");
    }

    objectName: "issueTrackerPage"
    implicitWidth: 900
    implicitHeight: 600
    onIssuesChanged: if (issue === null && issues.length > 0)
        selected = issues[0].key
    onSelectedChanged: openIssue()
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
                        objectName: "issueTrackerFollowing"
                        Layout.fillWidth: true
                        text: {
                            if (page.tracker === null)
                                return qsTr("Waiting for the tracker…");
                            const parts = [qsTr("%n open issue(s)", "", page.issues.length)];
                            if (page.tracker.looking)
                                parts.push(qsTr("looking…"));
                            else if (page.tracker.checkedAt)
                                parts.push(qsTr("looked %1").arg(page.date(page.tracker.checkedAt)));
                            return parts.join("  ·  ");
                        }
                        color: page.muted
                        elide: Text.ElideRight
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }

                    ShellComboBox {
                        objectName: "issueTrackerRepository"
                        visible: page.repositories.length > 1
                        outline: true
                        implicitWidth: 200
                        model: [qsTr("All repositories")].concat(page.repositories.map(each => each.repository))
                        currentIndex: page.repositories.findIndex(each => each.repository === page.repository) + 1
                        Accessible.name: qsTr("Repository")
                        onActivated: index => page.repository = index === 0 ? "" : page.repositories[index - 1].repository
                    }

                    ShellComboBox {
                        visible: page.plugin.environments.length > 1
                        outline: true
                        implicitWidth: 180
                        model: page.plugin.environments.map(environment => page.environmentLabel(environment))
                        currentIndex: page.plugin.environments.indexOf(page.environment)
                        Accessible.name: qsTr("Machine")
                        onActivated: index => page.environment = page.plugin.environments[index]
                    }

                    ShellButton {
                        objectName: "issueTrackerIssues"
                        subtle: page.view !== "issues"
                        text: qsTr("Issues")
                        onClicked: page.view = "issues"
                    }

                    ShellButton {
                        objectName: "issueTrackerProposals"
                        subtle: page.view !== "proposals"
                        text: page.proposed > 0 ? qsTr("Proposals (%1)").arg(page.proposed) : qsTr("Proposals")
                        onClicked: page.view = "proposals"
                    }

                    ShellButton {
                        objectName: "issueTrackerRefresh"
                        subtle: true
                        enabled: page.tracker !== null && !page.tracker.looking
                        text: qsTr("Look now")
                        onClicked: page.start("refresh", {})
                    }

                    ShellButton {
                        objectName: "issueTrackerPrioritise"
                        enabled: page.repository !== "" && page.issues.length > 0
                        text: qsTr("Prioritise")
                        Accessible.description: qsTr("Starts the prioritising agent on this repository's queue")
                        onClicked: page.start("prioritise", {
                            repository: page.repository
                        })
                    }
                }

                Text {
                    objectName: "issueTrackerProblem"
                    Layout.fillWidth: true
                    visible: text.length > 0
                    text: page.refusal || (page.tracker?.problem ?? "")
                    color: page.warningColor
                    wrapMode: Text.Wrap
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: page.view === "issues"
            spacing: 0

            ListView {
                id: list

                objectName: "issueTrackerList"
                Layout.preferredWidth: Math.min(400, page.width * 0.42)
                Layout.fillHeight: true
                clip: true
                model: page.issues
                currentIndex: page.issues.findIndex(each => each.key === page.selected)
                keyNavigationEnabled: true
                boundsBehavior: Flickable.StopAtBounds
                onCurrentIndexChanged: if (currentIndex >= 0 && activeFocus)
                    page.selected = page.issues[currentIndex].key

                ScrollBar.vertical: ScrollBar {}

                delegate: Column {
                    id: entry

                    required property var modelData
                    required property int index

                    width: ListView.view.width

                    // The first issue of a repository names it.
                    Text {
                        width: entry.width
                        visible: page.repository === "" && (entry.index === 0 || page.issues[entry.index - 1].repository !== entry.modelData.repository)
                        leftPadding: 16
                        topPadding: entry.index > 0 ? 14 : 10
                        bottomPadding: 4
                        text: entry.modelData.repository
                        color: page.muted
                        font.pixelSize: Math.round(11 * Theme.fontScale)
                        font.weight: Font.Medium
                        font.capitalization: Font.AllUppercase
                    }

                    ItemDelegate {
                        id: row

                        readonly property var modelData: entry.modelData

                        objectName: "issueTracker:" + modelData.key
                        width: entry.width
                        leftPadding: 16
                        rightPadding: 12
                        topPadding: 6
                        bottomPadding: 6
                        highlighted: modelData.key === page.selected
                        Accessible.name: qsTr("%1 %2").arg(modelData.key).arg(modelData.title ?? "")
                        onClicked: {
                            page.selected = modelData.key;
                            list.currentIndex = entry.index;
                            list.forceActiveFocus();
                        }

                        background: Rectangle {
                            color: row.highlighted ? Theme.palette.color("sidebarRowSelected", "#27272a") : row.hovered ? Theme.palette.color("sidebarRowHover", "#1f1f23") : "transparent"
                        }

                        contentItem: ColumnLayout {
                            spacing: 2

                            Text {
                                Layout.fillWidth: true
                                text: "#" + row.modelData.number + "  " + (row.modelData.title ?? "")
                                color: page.foreground
                                elide: Text.ElideRight
                                font.pixelSize: Math.round(13 * Theme.fontScale)
                            }

                            Text {
                                Layout.fillWidth: true
                                text: page.issueMeta(row.modelData)
                                color: page.muted
                                elide: Text.ElideRight
                                font.pixelSize: Math.round(11 * Theme.fontScale)
                            }
                        }
                    }
                }

                Text {
                    anchors.centerIn: parent
                    width: parent.width - 48
                    visible: page.issues.length === 0 && page.tracker !== null && !page.tracker.looking
                    text: qsTr("No open issues here. Pick the repositories to follow in the tracker's settings if that is a surprise.")
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

            // The issue picked in the list, and what can be started from it.
            Flickable {
                id: detail

                objectName: "issueTrackerDetail"
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentHeight: about.implicitHeight + 32
                boundsBehavior: Flickable.StopAtBounds

                ScrollBar.vertical: ScrollBar {}

                ColumnLayout {
                    id: about

                    readonly property var issue: page.opened ?? page.issue
                    readonly property var thread: issue ? page.threads["implement:" + issue.key] : undefined

                    x: 20
                    y: 16
                    width: detail.width - 40
                    visible: issue !== null
                    spacing: 10

                    Text {
                        Layout.fillWidth: true
                        text: about.issue ? about.issue.key + "  " + (about.issue.title ?? "") : ""
                        color: page.foreground
                        wrapMode: Text.Wrap
                        font.pixelSize: Math.round(16 * Theme.fontScale)
                        font.weight: Font.Medium
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        Text {
                            Layout.fillWidth: true
                            text: {
                                const issue = about.issue;
                                if (!issue)
                                    return "";
                                const parts = [page.issueMeta(issue)];
                                if (issue.milestone)
                                    parts.push(qsTr("milestone %1").arg(issue.milestone));
                                if (issue.assignees.length > 0)
                                    parts.push(qsTr("assigned to %1").arg(issue.assignees.join(", ")));
                                if (issue.blockedBy.length > 0)
                                    parts.push(qsTr("blocked by %1").arg(issue.blockedBy.map(each => each.repository + "#" + each.number).join(", ")));
                                if (issue.subIssues.total > 0)
                                    parts.push(qsTr("%1 of %2 sub-issues done").arg(issue.subIssues.completed).arg(issue.subIssues.total));
                                return parts.filter(part => part.length > 0).join(" · ");
                            }
                            color: page.muted
                            wrapMode: Text.Wrap
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }

                        ShellButton {
                            subtle: true
                            text: qsTr("Open on GitHub")
                            onClicked: Qt.openUrlExternally(about.issue.url)
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        ShellButton {
                            objectName: "issueTrackerFollowUp"
                            subtle: true
                            text: qsTr("Ask follow-up")
                            Accessible.description: qsTr("Starts the follow-up agent to draft a question for this issue's reporter")
                            onClicked: page.start("followUp", {
                                repository: about.issue.repository,
                                number: about.issue.number
                            })
                        }

                        ShellButton {
                            objectName: "issueTrackerSummarise"
                            subtle: true
                            text: qsTr("Summarise")
                            Accessible.description: qsTr("Starts the summarising agent on this issue")
                            onClicked: page.start("summarise", {
                                repository: about.issue.repository,
                                number: about.issue.number
                            })
                        }

                        ShellButton {
                            objectName: "issueTrackerImplementThread"
                            visible: about.thread !== undefined
                            subtle: true
                            text: visible ? qsTr("Last implement: %1").arg(page.threadStatus(about.thread)) : ""
                            Accessible.description: qsTr("Opens the thread last started to implement this issue")
                            onClicked: page.openThread(about.thread)
                        }

                        ShellButton {
                            objectName: "issueTrackerImplement"
                            text: qsTr("Implement")
                            Accessible.description: qsTr("Starts the implementing agent on this issue in a worktree of its own")
                            onClicked: page.start("implement", {
                                repository: about.issue.repository,
                                number: about.issue.number
                            })
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: (about.issue?.pullRequests ?? []).length > 0
                        text: about.issue ? qsTr("Closing pull requests: %1").arg(about.issue.pullRequests.map(each => each.repository + "#" + each.number + " (" + (each.state ?? "") + ")").join(", ")) : ""
                        color: page.muted
                        wrapMode: Text.Wrap
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }

                    Text {
                        objectName: "issueTrackerBody"
                        Layout.fillWidth: true
                        text: about.issue?.body ?? (page.issue ? qsTr("Reading…") : "")
                        color: page.foreground
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                    }
                }
            }
        }

        // Every triage run, newest first. A proposed one waits here: applying
        // it is what reaches GitHub, dismissing it reaches nothing.
        ListView {
            id: runsList

            objectName: "issueTrackerRuns"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: page.view === "proposals"
            clip: true
            model: page.runs
            boundsBehavior: Flickable.StopAtBounds

            ScrollBar.vertical: ScrollBar {}

            delegate: ColumnLayout {
                id: run

                required property var modelData

                objectName: "issueTrackerRun:" + modelData.id
                width: ListView.view.width
                spacing: 6

                // Padding through margins of an inner column: a delegate's own
                // content starts at its top-left.
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    Layout.topMargin: 14
                    Layout.bottomMargin: 4
                    spacing: 6

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        Text {
                            Layout.fillWidth: true
                            text: page.runTitle(run.modelData)
                            color: page.foreground
                            elide: Text.ElideRight
                            font.pixelSize: Math.round(14 * Theme.fontScale)
                            font.weight: Font.Medium
                        }

                        Text {
                            text: page.runStatus(run.modelData)
                            color: run.modelData.status === "proposed" ? page.warningColor : run.modelData.status === "applied" ? page.successColor : page.muted
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }

                        ShellButton {
                            subtle: true
                            text: qsTr("Thread")
                            Accessible.description: qsTr("Opens this run's thread")
                            onClicked: page.openThread(run.modelData.threadId)
                        }

                        ShellButton {
                            objectName: "issueTrackerDiscard:" + run.modelData.id
                            visible: run.modelData.status === "proposed" || run.modelData.status === "done"
                            subtle: true
                            text: qsTr("Dismiss")
                            onClicked: page.start("discard", {
                                runId: run.modelData.id
                            })
                        }

                        ShellButton {
                            objectName: "issueTrackerApply:" + run.modelData.id
                            visible: run.modelData.status === "proposed"
                            text: qsTr("Apply")
                            Accessible.description: qsTr("Sends this proposal to GitHub: its labels and comments")
                            onClicked: page.start("apply", {
                                runId: run.modelData.id
                            })
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: (run.modelData.summary ?? "") !== ""
                        text: run.modelData.summary ?? ""
                        color: page.foreground
                        wrapMode: Text.Wrap
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: (run.modelData.error ?? "") !== ""
                        text: run.modelData.error ?? ""
                        color: page.warningColor
                        wrapMode: Text.Wrap
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }

                    Repeater {
                        model: run.modelData.report?.items ?? []

                        delegate: ColumnLayout {
                            id: entry

                            required property var modelData
                            required property int index

                            Layout.fillWidth: true
                            spacing: 2

                            Text {
                                Layout.fillWidth: true
                                text: {
                                    const parts = [qsTr("%1. %2#%3").arg(entry.index + 1).arg(entry.modelData.repository).arg(entry.modelData.number)];
                                    if (entry.modelData.priority)
                                        parts.push(entry.modelData.priority);
                                    if ((entry.modelData.labels ?? []).length > 0)
                                        parts.push(entry.modelData.labels.join(", "));
                                    if ((entry.modelData.duplicates ?? []).length > 0)
                                        parts.push(qsTr("duplicates %1").arg(entry.modelData.duplicates.map(each => "#" + each).join(", ")));
                                    if (entry.modelData.reason)
                                        parts.push(entry.modelData.reason);
                                    return parts.join(" · ");
                                }
                                color: page.foreground
                                wrapMode: Text.Wrap
                                font.pixelSize: Math.round(12 * Theme.fontScale)
                            }

                            Text {
                                Layout.fillWidth: true
                                Layout.leftMargin: 16
                                visible: (entry.modelData.comment ?? "") !== ""
                                text: entry.modelData.comment ?? ""
                                color: page.muted
                                wrapMode: Text.Wrap
                                textFormat: Text.PlainText
                                font.pixelSize: Math.round(12 * Theme.fontScale)
                            }
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: page.border
                }
            }

            Text {
                anchors.centerIn: parent
                width: parent.width - 48
                visible: page.runs.length === 0 && page.tracker !== null
                text: qsTr("No triage runs yet. Prioritise a repository, or ask for a follow-up or a summary from an issue.")
                color: page.muted
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: Math.round(13 * Theme.fontScale)
            }
        }
    }
}
