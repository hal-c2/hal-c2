import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The centre for a thread or draft route (js/centreViews.js): the route's
// thread from Threads (ThreadStore), or a draft's opening line with where it
// will run. Loading says so without moving; a thread whose MC stopped
// sending it says why and offers Retry.
//
// Web links open in the system browser; file links and files the agent
// changed open in the right panel (`panel.open`, RightPanelController). A reply's Revert asks
// first (RevertDialog), then rewinds as the diff panel does (ThreadDiff). "Jump to latest" is also the
// `timeline.jumpToLatest` command.
Item {
    id: view

    // The corner radius of layouts that round the centre.
    property real radius: 0
    readonly property var route: Shell.state.route ?? null
    readonly property bool draft: route !== null && route.kind === "draft"
    readonly property var model: draft ? null : Threads.timeline
    readonly property var workspace: Shell.state.workspace ?? null
    readonly property string status: model ? model.status : "loading"
    readonly property bool unreachable: !draft && status === "unreachable"
    readonly property bool loading: !draft && (model === null || (status === "loading" && model.count === 0))
    readonly property bool empty: !draft && status === "live" && model !== null && model.count === 0

    readonly property color textColor: Theme.palette.color("text", "#e4e4e7")
    readonly property color mutedColor: Theme.palette.color("textMuted", "#8b8b93")
    readonly property string uiFamily: Theme.fontUi.length > 0 ? Theme.fontUi : Qt.application.font.family

    // Where web addresses go: the system browser (tests keep them in).
    property var openExternally: url => Qt.openUrlExternally(url)

    // Web addresses leave the app; anything else is a path in the project.
    function openLink(link) {
        if (/^(https?|mailto):/i.test(link)) {
            view.openExternally(link);
            return;
        }
        let path = link.replace(/^file:\/\//i, "");
        // "src/cart.ts#L12" and "src/cart.ts:12:3" name the file and its line.
        const line = /#L(\d+)/.exec(path) ?? /:(\d+)(:\d+)?$/.exec(path);
        path = decodeURIComponent(path.replace(/#.*$/, "").replace(/(:\d+)+$/, ""));
        if (path.length === 0)
            return;
        const options = {
            tab: "files",
            path: path
        };
        if (line)
            options.line = Number(line[1]);
        Shell.dispatch("panel.open", options);
    }

    // A reply's changed file opens on that reply's turn in the diff.
    function openFile(path, tab, rowId) {
        const options = {
            tab: tab,
            path: path
        };
        const turn = tab === "diff" && view.model ? view.model.checkpointOf(rowId).turn : undefined;
        if (turn !== undefined)
            options.turn = turn;
        Shell.dispatch("panel.open", options);
    }

    // The same revert as the diff panel's (Panel.diff), on this reply's turn.
    function askRevert(rowId) {
        const checkpoint = view.model ? view.model.checkpointOf(rowId) : ({});
        if (checkpoint.turn !== undefined)
            revertDialog.ask(checkpoint.turn);
    }

    Component.onCompleted: {
        if (Keybindings.commands)
            Keybindings.commands.add("timeline.jumpToLatest", qsTr("Jump to latest"), () => timeline.scrollToEnd(), view);
    }

    Rectangle {
        anchors.fill: parent
        radius: view.radius
        color: Theme.palette.color("canvas", "#0b0b0d")
    }

    Timeline {
        id: timeline
        objectName: "threadTimeline"

        anchors.top: lineageBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: limitBanner.visible ? limitBanner.top : parent.bottom
        visible: !view.draft
        model: view.model
        showStatus: false
        onLinkActivated: link => view.openLink(link)
        onFileActivated: (path, tab, rowId) => view.openFile(path, tab, rowId)
        onRevertRequested: rowId => view.askRevert(rowId)
    }

    // Why the thread stopped following its MC, with a way to try again.
    Rectangle {
        id: problemBar
        objectName: "threadProblem"

        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: visible ? problemRow.implicitHeight + 16 : 0
        visible: view.unreachable
        color: Qt.alpha(Theme.palette.color("warning", "#f59e0b"), 0.1)

        RowLayout {
            id: problemRow
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            spacing: 12
            Label {
                Layout.fillWidth: true
                text: qsTr("This thread's MC cannot be reached: %1").arg(view.model ? view.model.problem : "")
                color: Theme.palette.color("warning", "#f59e0b")
                font.family: view.uiFamily
                font.pixelSize: Math.round(13 * Theme.fontScale)
                wrapMode: Text.Wrap
            }
            ShellButton {
                objectName: "threadRetry"
                text: qsTr("Retry")
                onClicked: Threads.reload(Threads.activeThread)
            }
        }
    }

    // Where the thread came from and the forks made of it.
    ThreadLineage {
        id: lineageBar

        anchors.top: setupCard.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: visible ? implicitHeight : 0
        visible: lineage !== null && !view.draft
    }

    // The agent stopped on a usage limit: when it resets and what to do until then.
    LimitRecoveryBanner {
        id: limitBanner

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: implicitHeight
        visible: recovery !== null && !view.draft
    }

    // How the thread's new worktree is being prepared.
    WorktreeSetupCard {
        id: setupCard

        anchors.top: problemBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: visible ? implicitHeight : 0
        visible: setup !== null && !view.draft
    }

    // Loading, an empty thread, or a draft's opening line. Static: nothing
    // here repaints while it waits.
    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 640)
        spacing: 8
        visible: view.draft || view.loading || view.empty

        Label {
            objectName: "threadPlaceholder"
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            color: view.draft ? view.textColor : view.mutedColor
            font.family: view.uiFamily
            font.pixelSize: view.draft ? 24 : 13
            text: {
                if (view.draft) {
                    const project = view.workspace ? view.workspace.projectTitle : "";
                    return project ? qsTr("What should we build in %1?").arg(project) : qsTr("Add a project to start");
                }
                return view.loading ? qsTr("Loading…") : qsTr("Send a message to start the conversation.");
            }
        }
        Label {
            objectName: "draftContext"
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            visible: view.draft && text.length > 0
            color: view.mutedColor
            font.family: view.uiFamily
            font.pixelSize: Math.round(13 * Theme.fontScale)
            elide: Text.ElideMiddle
            text: {
                if (!view.workspace)
                    return "";
                const parts = [];
                if (view.workspace.envModeLabel)
                    parts.push(view.workspace.envModeLabel);
                if (view.workspace.branch)
                    parts.push(view.workspace.branch);
                return parts.join(" · ");
            }
        }
    }

    RevertDialog {
        id: revertDialog
        source: Panel.diff
    }
}
