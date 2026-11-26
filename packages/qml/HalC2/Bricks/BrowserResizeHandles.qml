pragma ComponentBehavior: Bound
import QtQuick
import HalC2.Shell
import "js/browser.js" as BrowserJs

// The edges of a device-sized page (BrowserPanel) that resize it: the right
// edge, the bottom edge and the corner between them, dragged, or focused and
// moved with the arrow keys (10 pixels a press, 50 with Shift) and applied
// once the keys pause. Until a size is applied (`picked`) it is `size`; a
// size that comes another way (`source`) drops it.
//
//   BrowserResizeHandles { anchors.fill: parent; frame: ...; source: page.viewport; onPicked: viewport => page.setViewport(viewport) }
Item {
    id: handles

    objectName: "browserEdges"

    // Where the page is drawn, and at what scale.
    property rect frame
    property real pageScale: 1
    // The space the page is centred in.
    property size room
    // The page's size, as the MC has it or was last picked.
    property var source: ({ _tag: "fill" })
    // Width over height while the aspect ratio is locked, else 0.
    property real ratio: 0
    property bool busy: false
    // The size a drag or the keys show, until it is picked; else null.
    property var size: null
    // Where a drag started: the size, the pointer and the scale.
    property var start: null
    property point pressedAt
    property real startScale: 1

    signal picked(var viewport)

    function drop() {
        settle.stop();
        start = null;
        size = null;
    }

    function freeform(next) {
        return { _tag: "freeform", width: next.width, height: next.height };
    }

    // Picks the size shown, if it is not the page's already.
    function pick() {
        const next = size;
        start = null;
        if (next === null || (next.width === source.width && next.height === source.height)) {
            size = null;
            return;
        }
        picked(next);
        size = null;
    }

    onSourceChanged: drop()

    Timer {
        id: settle

        interval: 150
        onTriggered: handles.pick()
    }

    Repeater {
        model: [
            { name: "right", dx: 1, dy: 0, cursor: Qt.SizeHorCursor },
            { name: "bottom", dx: 0, dy: 1, cursor: Qt.SizeVerCursor },
            { name: "corner", dx: 1, dy: 1, cursor: Qt.SizeFDiagCursor }
        ]

        delegate: Item {
            id: edge

            required property var modelData
            readonly property int dx: modelData.dx
            readonly property int dy: modelData.dy

            objectName: "browserEdge-" + modelData.name
            x: dx ? handles.frame.x + handles.frame.width : handles.frame.x
            y: dy ? handles.frame.y + handles.frame.height : handles.frame.y
            width: dx ? 10 : handles.frame.width
            height: dy ? 10 : handles.frame.height
            enabled: !handles.busy
            activeFocusOnTab: true
            Accessible.role: Accessible.Grip
            Accessible.name: modelData.name === "right" ? qsTr("Resize from the right edge") : modelData.name === "bottom" ? qsTr("Resize from the bottom edge") : qsTr("Resize from the corner")

            Keys.onPressed: event => {
                const step = event.modifiers & Qt.ShiftModifier ? 50 : 10;
                const across = event.key === Qt.Key_Right ? 1 : event.key === Qt.Key_Left ? -1 : 0;
                const down = event.key === Qt.Key_Down ? 1 : event.key === Qt.Key_Up ? -1 : 0;
                const byX = edge.dx ? across * step : 0;
                const byY = edge.dy ? down * step : 0;
                if (byX === 0 && byY === 0)
                    return;
                event.accepted = true;
                const from = handles.size ?? handles.source;
                handles.size = handles.freeform(BrowserJs.resized(from, byX, byY, handles.ratio));
                settle.restart();
            }

            // Where focus is, for the keys.
            Rectangle {
                anchors.fill: parent
                visible: edge.activeFocus || drag.containsMouse || drag.pressed
                color: Theme.palette.color("accent", "#2563eb")
                opacity: 0.5
                radius: 2
            }

            MouseArea {
                id: drag

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: edge.modelData.cursor
                preventStealing: true
                onPressed: mouse => {
                    edge.forceActiveFocus();
                    settle.stop();
                    handles.start = handles.size ?? handles.source;
                    handles.pressedAt = mapToItem(handles, mouse.x, mouse.y);
                    handles.startScale = handles.pageScale;
                }
                onPositionChanged: mouse => {
                    if (handles.start === null)
                        return;
                    const at = mapToItem(handles, mouse.x, mouse.y);
                    handles.size = handles.freeform(BrowserJs.dragged(handles.start, edge.dx ? at.x - handles.pressedAt.x : 0, edge.dy ? at.y - handles.pressedAt.y : 0, handles.room, handles.startScale, handles.ratio));
                }
                onReleased: if (handles.start !== null)
                    handles.pick()
                onCanceled: handles.drop()
            }
        }
    }
}
