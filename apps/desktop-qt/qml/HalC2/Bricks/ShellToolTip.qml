import QtQuick
import HalC2.Shell

// The one look of the app's tooltips. ShellWindow hands it the engine's
// shared attached tooltip (`ToolTip.toolTip`), so `ToolTip.text` on any
// control draws on the popover surface whatever the Controls style: the
// overlay fill (solid), a strong hairline, the meta type step and a small
// radius. It shows and hides at once.
//
// It also watches the window, catching nothing, to keep tips honest: a
// press anywhere in the window puts the tip away, and a tip opens only for a
// pointer that moved onto its control, never for a control that moved, loaded
// or scrolled under a resting one, nor again after a press until the pointer
// moves. A tip a focused field asks for (its problem) or a control focused
// from the keyboard still opens, as do tips in popups, which lie above this
// layer.
Item {
    id: look

    // The ToolTip to dress: the shared instance attached tooltips use.
    property var tip: null

    // The last real move of the pointer over the window: when, and where.
    property real movedAt: 0
    property point movedTo: Qt.point(-1, -1)
    // A press came after that move.
    property bool pressedSinceMove: false
    // The control whose tip was held back; it opens once the pointer moves.
    property Item heldFor: null

    function underWindow(item) {
        for (let at = item; at; at = at.parent) {
            if (at === look.parent)
                return true;
        }
        return false;
    }

    // A tip opens on the delay after its control is entered, so a pointer
    // that entered it moved no longer ago than that, give or take a timer.
    function stale() {
        return look.pressedSinceMove || Date.now() - look.movedAt > look.tip.delay + 150;
    }

    // A layer over the window, so it sees a press before any control takes it.
    anchors.fill: parent
    z: 1000000

    // On the window's content, an ancestor of every control: on the layer it
    // would take the hover from them.
    HoverHandler {
        parent: look.parent
        onPointChanged: {
            const at = point.scenePosition;
            if (at.x === look.movedTo.x && at.y === look.movedTo.y)
                return;
            look.movedTo = Qt.point(at.x, at.y);
            look.movedAt = Date.now();
            look.pressedSinceMove = false;
            const owner = look.heldFor;
            look.heldFor = null;
            if (owner && look.tip !== null && look.tip.parent === owner && !look.tip.visible && owner.contains(owner.mapFromItem(null, at.x, at.y)))
                look.tip.open();
        }
    }

    PointHandler {
        acceptedButtons: Qt.AllButtons
        onActiveChanged: {
            if (!active)
                return;
            look.pressedSinceMove = true;
            look.heldFor = null;
            if (look.tip !== null && look.tip.visible)
                look.tip.close();
        }
    }

    Connections {
        target: look.tip

        function onOpened() {
            const owner = look.tip.parent;
            // A text field has no visualFocus; a button a click focused has it false.
            if (owner && owner.activeFocus && owner.visualFocus !== false || !look.underWindow(owner))
                return;
            if (look.stale()) {
                look.tip.close();
                look.heldFor = owner;
            }
        }
    }

    // Held in properties, not children: a popup adopts a background or
    // content item only when it has no visual parent yet.
    readonly property Item surface: Rectangle {
        readonly property color overlay: Theme.palette.color("surfaceOverlay", "#22262e")

        objectName: "toolTipSurface"
        radius: Theme.radiusSm
        // Solid whatever the glass opacity: a tip is read over anything.
        color: Qt.rgba(overlay.r, overlay.g, overlay.b, 1)
        border.color: Theme.palette.color("borderStrong", "#343a44")
        border.width: 1
    }

    readonly property Item label: Text {
        objectName: "toolTipLabel"
        text: look.tip ? look.tip.text : ""
        color: Theme.palette.color("ink", "#e4e4e7")
        font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
        font.pixelSize: Theme.type.meta.size
        lineHeight: Theme.type.meta.lineHeight
        lineHeightMode: Text.FixedHeight
        wrapMode: Text.Wrap
    }

    Binding {
        when: look.tip !== null
        target: look.tip
        property: "background"
        value: look.surface
    }
    Binding {
        when: look.tip !== null
        target: look.tip
        property: "contentItem"
        value: look.label
    }
    Binding {
        when: look.tip !== null
        target: look.tip
        property: "topPadding"
        value: Theme.space.xs
    }
    Binding {
        when: look.tip !== null
        target: look.tip
        property: "bottomPadding"
        value: Theme.space.xs
    }
    Binding {
        when: look.tip !== null
        target: look.tip
        property: "leftPadding"
        value: Theme.space.sm
    }
    Binding {
        when: look.tip !== null
        target: look.tip
        property: "rightPadding"
        value: Theme.space.sm
    }
    Binding {
        when: look.tip !== null
        target: look.tip
        property: "enter"
        value: null
    }
    Binding {
        when: look.tip !== null
        target: look.tip
        property: "exit"
        value: null
    }
}
