import QtQuick
import HalC2.Shell

// The thread's terminal drawer: the page's own drawer, loaded as the embed
// route (`?surface=terminal`) in a web surface the shell places, so it can
// sit under the Composer the way the page keeps it under its own composer.
// Open flag, height and route come from Shell.state.workspace; dragging the
// top edge hands the height back with terminal.resize, and the page persists
// it with the drawer's other state. Not animated: every frame of it would
// relayout the web surface above (see RightPanel).
Item {
    id: drawer

    readonly property var model: Shell.state.workspace ?? null
    readonly property bool available: model !== null && model.terminalAvailable === true
    readonly property bool open: available && model.terminalOpen === true
    readonly property int minimumHeight: 180
    readonly property int pageHeight: available && typeof model.terminalHeight === "number" ? model.terminalHeight : 280
    readonly property url embedUrl: {
        if (!available) {
            return "";
        }
        const page = Shell.pageUrl.toString();
        const origin = page.match(/^(https?:\/\/[^/]+)/);
        return origin ? origin[1] + model.terminalEmbedPath : "";
    }

    // The web surface's corner radius, for a rice that cards the drawer.
    property real radius: 0

    // The height while the edge is dragged and until the page publishes it
    // back; -1 when the page's height is the one shown.
    property int localHeight: -1

    property bool focusPending: false

    // The page's terminal focus requests already acted on; a new one (the
    // drawer opened, a terminal added or closed) moves the keyboard in here.
    property int handledFocusRequest: 0

    // What had the keyboard before the drawer took it (usually the composer),
    // and whether the drawer still held it when it last was open: closing
    // hands focus back, as the page returns it to its composer.
    property Item focusBefore: null
    property bool hadFocus: false
    readonly property bool bodyFocused: body.item !== null && body.item.activeFocus

    function focusTerminal() {
        if (!drawer.available) return;
        drawer.focusPending = true;
        if (!drawer.open) Shell.dispatch("terminal.toggle");
        drawer.applyPendingFocus();
    }

    function applyPendingFocus() {
        if (drawer.focusPending && drawer.open && body.status === Loader.Ready && !body.item.loading) {
            const previous = drawer.Window.activeFocusItem;
            if (previous !== null && previous !== body.item) drawer.focusBefore = previous;
            body.item.forceActiveFocus();
            drawer.focusPending = false;
        }
    }

    onOpenChanged: {
        if (drawer.open) {
            Qt.callLater(drawer.applyPendingFocus);
        } else if (drawer.hadFocus) {
            drawer.hadFocus = false;
            if (drawer.focusBefore !== null && drawer.focusBefore.visible && drawer.focusBefore.enabled)
                drawer.focusBefore.forceActiveFocus();
            drawer.focusBefore = null;
        }
    }
    onBodyFocusedChanged: if (drawer.open) drawer.hadFocus = drawer.bodyFocused

    // The page clamps the same way: never shorter than a few rows, never
    // more than three quarters of the window.
    function clampHeight(height) {
        const ceiling = Math.max(minimumHeight, Math.floor(drawer.Window.height * 0.75));
        return Math.min(Math.max(Math.round(height), minimumHeight), ceiling);
    }

    implicitHeight: open ? clampHeight(localHeight >= 0 ? localHeight : pageHeight) : 0
    visible: open

    onModelChanged: {
        if (!edgeDrag.active) {
            localHeight = -1;
        }
        const request = available ? model.terminalFocusRequestId ?? 0 : 0;
        if (request !== handledFocusRequest) {
            handledFocusRequest = request;
            if (request > 0 && model.terminalOpen === true) {
                focusPending = true;
                Qt.callLater(applyPendingFocus);
            }
        }
    }

    // The hairline over the drawer; a carded drawer has the card's edge instead.
    Rectangle {
        id: edgeLine
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: drawer.radius > 0 ? 0 : 1
        visible: height > 0
        color: Theme.palette.color("border", "#27272a")
    }

    Loader {
        id: body

        onLoaded: drawer.applyPendingFocus()

        readonly property bool wanted: drawer.open && drawer.embedUrl.toString().length > 0

        anchors.top: edgeLine.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        // Created on first open and kept: the document holds the terminals.
        active: false
        onWantedChanged: {
            if (wanted) {
                active = true;
            }
        }
        Component.onCompleted: {
            if (wanted) {
                active = true;
            }
        }

        sourceComponent: WebSurface {
            surfaceId: "terminal"
            sleepsWhenHidden: true
            radius: drawer.radius
            Component.onCompleted: url = drawer.embedUrl
            onLoadingChanged: if (!loading) drawer.applyPendingFocus()
        }
    }

    // The drag edge sits over the top of the web surface, like the page's
    // own handle does.
    Item {
        id: edge
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 6

        HoverHandler {
            cursorShape: Qt.SplitVCursor
        }

        DragHandler {
            id: edgeDrag

            property int startHeight: 0

            target: null
            xAxis.enabled: false
            onActiveChanged: {
                if (active) {
                    startHeight = drawer.height;
                    drawer.localHeight = startHeight;
                } else if (drawer.localHeight !== drawer.clampHeight(drawer.pageHeight)) {
                    Shell.dispatch("terminal.resize", {
                        height: drawer.localHeight
                    });
                } else {
                    drawer.localHeight = -1;
                }
            }
            onTranslationChanged: {
                if (active) {
                    drawer.localHeight = drawer.clampHeight(startHeight - translation.y);
                }
            }
        }
    }
}
