pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// The route's centre, and a thread's stage: the conversation (timeline and
// composer) with the stage beside it, or, with the timeline put away, the
// stage over the composer and a line of what the agent did last. Where the two
// do not fit side by side, one shows at a time and that line switches.
//
//   ThreadArea { routeKind: window.route?.kind ?? ""; bodies: panelBodies }
Item {
    id: threadArea

    // The route's kind (js/centreViews.js); only a thread has a stage.
    property string routeKind: ""
    // The tab bodies the stage borrows, shared with the side panel.
    required property PanelBodies bodies
    // The narrowest the conversation goes beside the stage.
    property int threadMinimumWidth: 360
    property alias centreView: centreHost
    property alias composer: composerView
    property alias stage: stageView
    // The conversation's own room, for drops on it: its width beside the
    // stage, and where it starts under a stage over the timeline.
    readonly property real conversationWidth: conversation.width
    readonly property real conversationTop: stageView.visible && focusMode ? stageRoom.height : 0

    readonly property var stageModel: Shell.state.panel?.stage ?? null
    readonly property bool staged: routeKind === "thread" && (stageModel?.tabs ?? []).length > 0
    readonly property bool focusMode: staged && stageModel.focus === true
    readonly property bool narrow: width < threadArea.threadMinimumWidth + stageView.minimumWidth + 1
    readonly property bool timelineShown: !staged || !focusMode
    readonly property bool besideShown: staged && !focusMode && !narrow
    // The conversation's width beside the stage: the one being
    // dragged to, the controller's, or 40%.
    property int dragWidth: -1
    readonly property int chatWidth: {
        const kept = dragWidth >= 0 ? dragWidth : (stageModel?.chatWidth ?? 0);
        const wanted = kept > 0 ? kept : Math.round(width * 0.4);
        return Math.max(threadArea.threadMinimumWidth, Math.min(wanted, width - stageView.minimumWidth - 1));
    }

    ColumnLayout {
        id: conversation

        width: threadArea.besideShown ? threadArea.chatWidth : threadArea.width
        height: threadArea.height
        spacing: 0

        // The route's centre: a thread, draft, home, pull requests or usage.
        CentreHost {
            id: centreHost
            objectName: "centreHost"

            Layout.fillWidth: true
            Layout.fillHeight: true
            kind: threadArea.routeKind
            visible: threadArea.timelineShown
        }

        // Where the stage lies while the timeline is put away.
        Item {
            id: stageRoom

            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !threadArea.timelineShown
        }

        // What the agent did last while the timeline is put
        // away, or the stage's tabs while it is out of room;
        // a click shows the other.
        Rectangle {
            objectName: "stageActivity"
            Layout.fillWidth: true
            Layout.preferredHeight: 30
            visible: threadArea.staged && (threadArea.focusMode || threadArea.narrow)
            color: activityTap.hovered ? Theme.palette.color("surface", "#141416") : Theme.palette.color("chrome", "#0b0b0d")
            Accessible.role: Accessible.Button
            Accessible.name: activityAction.text
            Accessible.onPressAction: Shell.dispatch("stage.toggleFocus")

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                height: 1
                color: Theme.palette.color("border", "#27272a")
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 8

                // Still while the agent works: a dot, not a spinner.
                Rectangle {
                    Layout.preferredWidth: 6
                    Layout.preferredHeight: 6
                    radius: 3
                    visible: threadArea.focusMode
                    color: Threads.timeline?.working === true ? Theme.palette.color("accent", "#2563eb") : Theme.palette.color("textMuted", "#8b8b93")
                }

                Text {
                    objectName: "stageActivityText"
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: {
                        if (!threadArea.focusMode) {
                            const count = threadArea.stageModel?.tabs.length ?? 0;
                            return count === 1 ? qsTr("1 tab in the centre") : qsTr("%1 tabs in the centre").arg(count);
                        }
                        const latest = String(Threads.timeline?.latest ?? "");
                        return latest.length > 0 ? latest : qsTr("Nothing in this thread yet");
                    }
                    color: Theme.palette.color("text", "#e4e4e7")
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }

                Text {
                    id: activityAction
                    text: threadArea.focusMode ? qsTr("Show the timeline") : qsTr("Show the tabs")
                    color: Theme.palette.color("textMuted", "#8b8b93")
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }
            }

            HoverHandler {
                id: activityTap
                cursorShape: Qt.PointingHandCursor
            }

            TapHandler {
                onTapped: Shell.dispatch("stage.toggleFocus")
            }
        }

        Composer {
            id: composerView

            // ConversationDrop (DefaultLayout) takes files over the conversation.
            takesDrops: false
            Layout.fillWidth: true
            visible: ready
            conversationScrolled: centreHost.conversationScrolled
        }
    }

    // Between the conversation and the stage: drag to resize,
    // double click for the default width.
    Rectangle {
        objectName: "stageSplitter"
        x: threadArea.chatWidth
        width: 1
        height: threadArea.height
        visible: threadArea.besideShown
        color: Theme.palette.color("border", "#27272a")

        MouseArea {
            property real pressX: 0
            property int pressWidth: 0

            anchors.centerIn: parent
            width: 7
            height: parent.height
            cursorShape: Qt.SplitHCursor
            preventStealing: true
            onPressed: mouse => {
                pressX = mapToItem(threadArea, mouse.x, 0).x;
                pressWidth = threadArea.chatWidth;
            }
            onPositionChanged: mouse => {
                if (pressed)
                    threadArea.dragWidth = Math.round(pressWidth + mapToItem(threadArea, mouse.x, 0).x - pressX);
            }
            onReleased: {
                const width = threadArea.chatWidth;
                threadArea.dragWidth = -1;
                if (width !== (threadArea.stageModel?.chatWidth ?? 0))
                    Shell.dispatch("stage.resize", {
                        width: width
                    });
            }
            onCanceled: threadArea.dragWidth = -1
            onDoubleClicked: Shell.dispatch("stage.resize", {})
        }
    }

    Stage {
        id: stageView

        readonly property int minimumWidth: 360

        bodies: threadArea.bodies
        visible: threadArea.staged && (threadArea.focusMode || threadArea.besideShown)
        x: threadArea.focusMode ? 0 : threadArea.chatWidth + 1
        width: threadArea.focusMode ? threadArea.width : threadArea.width - x
        height: threadArea.focusMode ? stageRoom.height : threadArea.height
    }

    // While no stage shows, a side panel tab dragged over the
    // conversation's right half goes to the centre.
    DropArea {
        id: centreDrop

        objectName: "centreDrop"
        x: Math.round(threadArea.width / 2)
        width: threadArea.width - x
        height: threadArea.height - (composerView.visible ? composerView.height : 0)
        keys: ["hal-c2/panel-tab"]
        enabled: threadArea.routeKind === "thread" && !stageView.visible && threadArea.bodies.dragging.length > 0
        onDropped: drop => {
            const id = threadArea.bodies.dragging;
            drop.accept();
            // After the drag has let go of the tab it moves.
            Qt.callLater(() => Shell.dispatch("rightPanel.dock", {
                    id: id,
                    dock: "stage"
                }));
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: 8
            visible: centreDrop.enabled
            radius: 8
            color: Qt.alpha(Theme.palette.color("accent", "#2563eb"), centreDrop.containsDrag ? 0.18 : 0.06)
            border.color: Theme.palette.color("accent", "#2563eb")

            Text {
                anchors.centerIn: parent
                text: qsTr("Show in the centre")
                color: Theme.palette.color("text", "#e4e4e7")
                font.pixelSize: Math.round(13 * Theme.fontScale)
            }
        }
    }
}
