import QtQuick
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// Above a planner thread's conversation: the action and the tasks it runs on, where
// its run is and what it proposes, and applying it. A thread working on a task
// shows that task with its status and progress instead. Follows the plugin's
// `threads` topic, and `plan` for a task's thread; the changes themselves are on
// the Planner page.
Rectangle {
    id: header

    property var plugin
    property var thread
    property var threads: ({})
    // The plan, followed only for a thread working on a task.
    property var plan: null
    readonly property var run: thread !== null ? (threads[thread.id] ?? null) : null
    readonly property string status: run?.status ?? ""
    readonly property bool work: run?.kind === "work"
    readonly property var task: work && plan !== null ? (plan.items ?? []).find(item => item.id === run.itemId) ?? null : null
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
    property int watching: -1
    property int watchingPlan: -1
    property string followed: ""
    property bool applying: false
    // Why the last apply from here failed, until the run changes.
    property string refusal: ""

    // Follows `threads` on the MC of the thread, which a header keeps while the
    // user moves between planner threads.
    function follow() {
        const environment = header.thread?.environmentId ?? "";
        if (header.watching >= 0 && environment === header.followed)
            return;
        header.plugin.unwatch(header.watching);
        header.plugin.unwatch(header.watchingPlan);
        header.watchingPlan = -1;
        header.plan = null;
        header.followed = environment;
        header.threads = {};
        header.watching = header.plugin.watch("threads", value => header.threads = value ?? {}, environment || undefined);
    }

    function followPlan() {
        if (header.work && header.watchingPlan < 0)
            header.watchingPlan = header.plugin.watch("plan", value => header.plan = value ?? null, header.followed || undefined);
    }

    function apply() {
        header.applying = true;
        header.refusal = "";
        header.plugin.call("apply", { runId: header.run.runId }, (result, error) => {
            header.applying = false;
            if (error)
                header.refusal = error;
        }, header.followed || undefined);
    }

    function statusText() {
        switch (header.status) {
        case "queued":
            return qsTr("Waiting for a free agent");
        case "running":
            return header.work ? qsTr("The agent is working on it") : qsTr("The agent is running");
        case "failed":
            return qsTr("Failed");
        case "proposed":
            if (header.run.changes === 0 && header.run.health)
                return qsTr("Proposes a status update");
            return header.run.changes === 1 ? qsTr("Proposes 1 change") : qsTr("Proposes %1 changes").arg(header.run.changes);
        case "applied":
            return qsTr("Applied");
        case "done":
            return qsTr("Done");
        default:
            return "";
        }
    }

    function taskStatus(status) {
        switch (status) {
        case "todo":
            return qsTr("To do");
        case "doing":
            return qsTr("In progress");
        case "blocked":
            return qsTr("Blocked");
        case "done":
            return qsTr("Done");
        case "dropped":
            return qsTr("Dropped");
        default:
            return "";
        }
    }

    objectName: "plannerHeader"
    visible: run !== null
    implicitHeight: run !== null ? column.implicitHeight + 16 : 0
    color: Theme.palette.color("surface", "#18181b")
    onStatusChanged: refusal = ""
    onThreadChanged: follow()
    onWorkChanged: followPlan()
    Component.onCompleted: {
        follow();
        followPlan();
    }

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
                objectName: "plannerHeaderTitle"
                Layout.fillWidth: true
                text: header.work ? (header.task?.title ?? (header.run?.items ?? []).join(", ")) : (header.run?.label ?? "")
                color: header.foreground
                elide: Text.ElideRight
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.Medium
            }

            Text {
                objectName: "plannerHeaderTask"
                visible: header.task !== null
                text: header.task ? qsTr("%1 · %2% done").arg(header.taskStatus(header.task.status)).arg(header.task.derivedProgress ?? header.task.progress ?? 0) : ""
                color: header.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }

            ShellButton {
                objectName: "plannerHeaderApply"
                visible: header.status === "proposed"
                primary: true
                // Every proposed run has changes or a status update to apply.
                enabled: !header.applying
                text: header.applying ? qsTr("Applying…") : qsTr("Apply")
                onClicked: header.apply()
            }
        }

        Text {
            objectName: "plannerHeaderStatus"
            Layout.fillWidth: true
            text: {
                const run = header.run;
                if (run === null)
                    return "";
                const on = header.work ? "" : (run.items ?? []).join(", ");
                return [on, header.statusText()].filter(part => part.length > 0).join(" · ");
            }
            color: header.muted
            elide: Text.ElideRight
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        Text {
            objectName: "plannerHeaderProblem"
            Layout.fillWidth: true
            visible: text.length > 0
            text: header.refusal
            color: header.errorColor
            wrapMode: Text.Wrap
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }
    }
}
