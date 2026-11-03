pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// The route's centre, and a thread's stage: the conversation (timeline and
// composer) with the stage beside it, or the stage across the centre, its
// strip switching between the timeline and its tabs over the composer (with a
// line of what the agent did last while a tab shows). Where the two do not fit
// side by side, the stage is always across the centre. A layout with a
// composer of its own uses CentreHost, which has none.
//
//   ThreadArea { routeKind: window.route?.kind ?? ""; bodies: window.panelBodies }
Item {
    id: threadArea

    // The route's kind (js/centreViews.js); only a thread has a stage.
    property string routeKind: ""
    // The tab bodies the stage borrows, shared with the side panel; no
    // stage without them.
    required property PanelBodies bodies
    // Whether the conversation has its composer under the timeline.
    property bool composerShown: true
    // The corner radius of layouts that round the centre: the route view's
    // corners, and the stage's outer ones.
    property real radius: 0
    // Whether the route's view is a conversation scrolled away from its latest output.
    readonly property bool conversationScrolled: centreHost.conversationScrolled
    // The narrowest the conversation goes beside the stage.
    property int threadMinimumWidth: 360
    property alias centreView: centreHost
    readonly property Composer composer: composerView.item as Composer
    property alias stage: stageView
    // The conversation's own room, for drops on it: its width beside the
    // stage, and where it starts under a stage over the timeline.
    readonly property real conversationWidth: conversation.width
    readonly property real conversationTop: oneAtATime ? stageRoom.height : 0

    readonly property var stageModel: Shell.state.panel?.stage ?? null
    readonly property bool staged: bodies !== null && routeKind === "thread" && (stageModel?.tabs ?? []).length > 0
    readonly property bool focusMode: staged && stageModel.focus === true
    readonly property bool narrow: width < threadArea.threadMinimumWidth + stageView.minimumWidth + 1
    // The stage across the centre, showing the timeline or a tab.
    readonly property bool oneAtATime: staged && (focusMode || narrow)
    readonly property bool timelineChosen: oneAtATime && (!focusMode || stageModel.timeline === true)
    readonly property bool timelineShown: !oneAtATime || timelineChosen
    readonly property bool besideShown: staged && !oneAtATime
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

        // Where the stage lies across the centre: all of it over the composer,
        // or its strip over the timeline.
        Item {
            id: stageRoom

            Layout.fillWidth: true
            Layout.fillHeight: !threadArea.timelineChosen
            Layout.preferredHeight: threadArea.timelineChosen ? stageView.stripHeight : 0
            visible: threadArea.oneAtATime
        }

        // The route's view: a thread, draft, home, pull requests or usage.
        RouteView {
            id: centreHost
            objectName: "routeView"

            Layout.fillWidth: true
            Layout.fillHeight: true
            kind: threadArea.routeKind
            radius: threadArea.radius
            visible: threadArea.timelineShown
        }

        // What the agent did last while a tab fills the centre; a click
        // shows the timeline.
        Rectangle {
            objectName: "stageActivity"
            Layout.fillWidth: true
            Layout.preferredHeight: 30
            // The centre's bottom corners where no composer lies under it.
            bottomLeftRadius: threadArea.composerShown ? 0 : threadArea.radius
            bottomRightRadius: bottomLeftRadius
            visible: threadArea.oneAtATime && !threadArea.timelineChosen
            color: activityTap.hovered ? Theme.palette.color("surface", "#141416") : Theme.palette.color("chrome", "#0b0b0d")
            Accessible.role: Accessible.Button
            Accessible.name: activityAction.text
            Accessible.onPressAction: Shell.dispatch("stage.showTimeline")

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
                    color: Threads.timeline?.working === true ? Theme.palette.color("accent", "#2563eb") : Theme.palette.color("textMuted", "#8b8b93")
                }

                Text {
                    objectName: "stageActivityText"
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: {
                        const latest = String(Threads.timeline?.latest ?? "");
                        return latest.length > 0 ? latest : qsTr("Nothing in this thread yet");
                    }
                    color: Theme.palette.color("text", "#e4e4e7")
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }

                Text {
                    id: activityAction
                    text: qsTr("Show the timeline")
                    color: Theme.palette.color("textMuted", "#8b8b93")
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }
            }

            HoverHandler {
                id: activityTap
                cursorShape: Qt.PointingHandCursor
            }

            TapHandler {
                onTapped: Shell.dispatch("stage.showTimeline")
            }
        }

        Loader {
            id: composerView

            Layout.fillWidth: true
            Layout.preferredHeight: visible ? item.implicitHeight : 0
            visible: (item as Composer)?.ready ?? false
            active: threadArea.composerShown

            sourceComponent: Composer {
                // ConversationDrop (DefaultLayout) takes files over the conversation.
                takesDrops: false
                conversationScrolled: centreHost.conversationScrolled
            }
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
        oneAtATime: threadArea.oneAtATime
        timelineChosen: threadArea.timelineChosen
        besideFits: !threadArea.narrow
        // Its corners on the centre's edge: the right ones beside the
        // conversation, the top ones over it.
        topLeftRadius: threadArea.oneAtATime ? threadArea.radius : 0
        topRightRadius: threadArea.radius
        bottomRightRadius: threadArea.oneAtATime ? 0 : threadArea.radius
        visible: threadArea.staged
        x: threadArea.oneAtATime ? 0 : threadArea.chatWidth + 1
        width: threadArea.oneAtATime ? threadArea.width : threadArea.width - x
        height: threadArea.oneAtATime ? stageRoom.height : threadArea.height
    }

    // While no pane shows, a side panel tab dragged over the
    // conversation's right half goes to the centre.
    DropArea {
        id: centreDrop

        objectName: "centreDrop"
        x: Math.round(threadArea.width / 2)
        y: threadArea.conversationTop
        width: threadArea.width - x
        height: threadArea.height - y - (composerView.visible ? composerView.height : 0)
        keys: ["hal-c2/panel-tab"]
        enabled: threadArea.routeKind === "thread" && (!threadArea.staged || threadArea.timelineChosen) && (threadArea.bodies?.dragging ?? "").length > 0
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
