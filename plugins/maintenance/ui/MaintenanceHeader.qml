import QtQuick
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// Above a maintenance thread's conversation: the repository and branch it
// maintains, where its run is, and opening its pull request. Follows the plugin's
// `threads` topic; the report itself is on the Maintenance page.
Rectangle {
    id: header

    property var plugin
    property var thread
    property var threads: ({})
    readonly property var run: thread !== null ? (threads[thread.id] ?? null) : null
    readonly property string status: run?.status ?? ""
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
    property int watching: -1
    property string followed: ""
    property bool publishing: false
    // Why the last call from here failed, until the run changes.
    property string refusal: ""

    // Follows `threads` on the MC of the thread, which a header keeps while the
    // user moves between maintenance threads.
    function follow() {
        const environment = header.thread?.environmentId ?? "";
        if (header.watching >= 0 && environment === header.followed)
            return;
        header.plugin.unwatch(header.watching);
        header.followed = environment;
        header.threads = {};
        header.watching = header.plugin.watch("threads", value => header.threads = value ?? {}, environment || undefined);
    }

    function call(method) {
        header.publishing = method === "publish";
        header.refusal = "";
        header.plugin.call(method, {
            runId: header.run.id
        }, (result, error) => {
            header.publishing = false;
            if (error)
                header.refusal = error;
        }, header.thread?.environmentId || undefined);
    }

    function statusText() {
        switch (header.status) {
        case "running":
            return header.run.mode === "report" ? qsTr("The agent is looking, changing nothing") : qsTr("The agent is maintaining");
        case "waiting":
            return qsTr("Waiting for you to open its pull request");
        case "publishing":
            return qsTr("Opening its pull request");
        case "kept":
            return qsTr("Kept in HAL-C2");
        case "published":
            return qsTr("Pull request open");
        case "done":
            return qsTr("Done");
        case "cancelled":
            return qsTr("Cancelled");
        case "failed":
            return qsTr("Failed");
        default:
            return "";
        }
    }

    objectName: "maintenanceHeader"
    visible: run !== null
    implicitHeight: run !== null ? column.implicitHeight + 16 : 0
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
                objectName: "maintenanceHeaderTitle"
                Layout.fillWidth: true
                text: header.run ? qsTr("Maintenance of %1").arg(header.run.repository) : ""
                color: header.foreground
                elide: Text.ElideRight
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.Medium
            }

            ShellButton {
                objectName: "maintenanceHeaderPublish"
                visible: header.status === "waiting" || header.status === "kept" || header.status === "publishing"
                primary: true
                enabled: header.status !== "publishing" && !header.publishing
                text: enabled ? qsTr("Open pull request") : qsTr("Opening…")
                onClicked: header.call("publish")
            }

            ShellButton {
                objectName: "maintenanceHeaderCancel"
                subtle: true
                visible: header.status === "running"
                text: qsTr("Cancel")
                onClicked: header.call("cancel")
            }

            ShellButton {
                subtle: true
                visible: (header.run?.prUrl ?? "").length > 0
                text: qsTr("Open on GitHub")
                onClicked: Qt.openUrlExternally(header.run.prUrl)
            }
        }

        Text {
            objectName: "maintenanceHeaderStatus"
            Layout.fillWidth: true
            text: {
                const run = header.run;
                if (run === null)
                    return "";
                const where = run.branch && run.base ? qsTr("%1 from %2").arg(run.branch).arg(run.base) : "";
                return [where, header.statusText()].filter(part => part && part.length > 0).join(" · ");
            }
            color: header.muted
            elide: Text.ElideRight
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        Text {
            objectName: "maintenanceHeaderProblem"
            Layout.fillWidth: true
            visible: text.length > 0
            text: header.refusal || header.run?.publishError || (header.status === "failed" ? header.run?.error ?? "" : "")
            color: header.errorColor
            wrapMode: Text.Wrap
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }
    }
}
