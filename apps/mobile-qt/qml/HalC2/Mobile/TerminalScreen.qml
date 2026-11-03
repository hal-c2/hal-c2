pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The thread's terminal on a screen of its own, one at a time. The Terminal is
// the desktop's (TerminalSplits); a finger, the soft keyboard and the row of keys
// it lacks are this screen's. Output is drawn while it is on screen only: the
// root unloads it, and the sessions keep the transcript a new Terminal restores.
//
// A finger scrolls as a wheel would, flicks on for a moment, and taps to bring
// the keyboard up or follow a link. Held down it picks a word, and the handle
// extends that by words; both are the Terminal's mouse selection, whose press
// stays down until the selection ends.
ColumnLayout {
    id: screen

    readonly property var mine: Shell.state.mobileTerminal ?? null
    readonly property bool connected: (Shell.state.connection ?? null)?.phase === "connected"
    readonly property var term: {
        void splits.cellRevision;
        return splits.terminalOf(Terminals.activeTerminalId);
    }
    // The Shift the Terminal reads as "select even if a program has the mouse".
    readonly property int selectAnyway: Qt.ShiftModifier
    // The user wants the keyboard. An offscreen window has none to ask.
    property bool keysWanted: true
    // The selection's press is still down.
    property bool selecting: false
    // In the finger area's coordinates.
    property point handleAt: Qt.point(0, 0)

    signal backRequested

    function showKeyboard() {
        keysWanted = true;
        if (term !== null)
            term.forceActiveFocus();
        Qt.inputMethod.show();
    }

    function hideKeyboard() {
        keysWanted = false;
        Qt.inputMethod.hide();
    }

    // Each visible row of the terminal as a line, rows counted as links are.
    function visibleLines() {
        if (term === null)
            return [];
        const top = Math.round(term.scrollOffset);
        const lines = [];
        let row = 0;
        for (const line of term.text().replace(/\r\n/g, "\n").split("\n")) {
            for (let at = 0; at === 0 || at < line.length; at += term.columns) {
                if (row >= top && row < top + term.rows)
                    lines.push(line.slice(at, at + term.columns));
                ++row;
            }
        }
        return lines;
    }

    function beginSelection(position) {
        if (term === null)
            return;
        // A second press inside the double-click interval selects a word.
        const at = fingers.mapToItem(term, position.x, position.y);
        events.mouse(term, "press", at.x, at.y, selectAnyway);
        events.mouse(term, "release", at.x, at.y, selectAnyway);
        events.mouse(term, "press", at.x, at.y, selectAnyway);
        selecting = true;
        handleAt = position;
    }

    function extendSelection(position) {
        handleAt = position;
        const at = fingers.mapToItem(term, position.x, position.y);
        events.mouse(term, "move", at.x, at.y);
    }

    function letGoOfSelection() {
        if (selecting && term !== null) {
            const at = fingers.mapToItem(term, handleAt.x, handleAt.y);
            events.mouse(term, "release", at.x, at.y);
        }
        selecting = false;
    }

    function endSelection() {
        letGoOfSelection();
        if (term !== null)
            term.clearSelection();
    }

    objectName: "terminalScreen"
    spacing: 0

    onTermChanged: {
        selecting = false;
        if (term !== null)
            term.forceActiveFocus();
    }
    Component.onCompleted: showKeyboard()

    TerminalEvents {
        id: events
    }

    // The keyboard comes and goes under the system's hand too.
    Connections {
        target: Qt.inputMethod
        function onVisibleChanged() {
            screen.keysWanted = Qt.inputMethod.visible;
        }
    }

    MobileBar {
        Layout.fillWidth: true
        canGoBack: true
        title: screen.mine !== null ? qsTr("%1 · %2").arg(screen.mine.terminal).arg(screen.mine.label) : qsTr("Terminal")
        onBackRequested: screen.backRequested()

        MobileIconButton {
            objectName: "terminalShowKeyboard"
            visible: !screen.keysWanted
            iconName: "keyboard"
            label: qsTr("Show the keyboard")
            onClicked: screen.showKeyboard()
        }

        MobileIconButton {
            objectName: "terminalMenu"
            iconName: "ellipsis"
            label: qsTr("Terminal actions")
            onClicked: Shell.dispatch("mobileTerminal.menu", { lines: screen.visibleLines() })
        }
    }

    // Comes back by itself once the connection does: the sessions attach again.
    ColumnLayout {
        Layout.fillWidth: true
        Layout.margins: 12
        visible: !screen.connected
        spacing: 8

        Label {
            objectName: "terminalWaiting"
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: qsTr("The terminal will load when the environment is ready.")
            color: Theme.palette.color("textMuted", "#a1a1aa")
        }

        MobileButton {
            objectName: "terminalReconnect"
            text: qsTr("Reconnect")
            subtle: true
            onClicked: Shell.dispatch("connection.retry")
        }
    }

    Item {
        Layout.fillWidth: true
        Layout.fillHeight: true

        TerminalSplits {
            id: splits

            objectName: "terminalSplits"
            anchors.fill: parent
            group: Terminals.activeGroup
            fontPointSize: screen.mine !== null ? screen.mine.textSize : 0
            inputHandler: (terminal, data) => Shell.dispatch("mobileTerminal.input", { data: data })
        }

        Connections {
            target: screen.term !== null ? screen.term.session : null
            function onOutput() {
                if (screen.selecting || screen.term.hasSelection)
                    screen.endSelection();
            }
        }

        // Fingers only: a mouse and its wheel go straight to the Terminal below.
        MultiPointTouchArea {
            id: fingers

            property point start: Qt.point(0, 0)
            property real lastY: 0
            property real lastMoved: 0
            property real velocity: 0
            property bool dragged: false
            property bool flickWasRunning: false
            readonly property bool flicking: flick.running

            objectName: "terminalFingers"
            anchors.fill: parent
            mouseEnabled: false
            maximumTouchPoints: 1

            onPressed: points => {
                const point = points[0];
                fingers.flickWasRunning = flick.running;
                flick.stop();
                fingers.start = Qt.point(point.x, point.y);
                fingers.lastY = point.y;
                fingers.lastMoved = Date.now();
                fingers.velocity = 0;
                fingers.dragged = false;
                hold.restart();
            }
            onUpdated: points => {
                const point = points[0];
                if (screen.selecting) {
                    screen.extendSelection(Qt.point(point.x, point.y));
                    return;
                }
                if (!fingers.dragged && Math.abs(point.y - fingers.start.y) + Math.abs(point.x - fingers.start.x) < 8)
                    return;
                fingers.dragged = true;
                hold.stop();
                const now = Date.now();
                // Whole pixels, keeping the rest: the Terminal counts rows from them.
                const moved = Math.round(point.y - fingers.lastY);
                fingers.velocity = moved / Math.max(1, now - fingers.lastMoved);
                fingers.lastMoved = now;
                fingers.lastY += moved;
                events.wheel(screen.term, moved);
            }
            onReleased: points => {
                const point = points[0];
                hold.stop();
                if (screen.selecting)
                    return;
                if (fingers.dragged) {
                    // A finger that stopped before lifting leaves the output where it is.
                    if (!Terminals.reduceMotion && Date.now() - fingers.lastMoved < 100 && Math.abs(fingers.velocity) > 0.2)
                        flick.begin(fingers.velocity);
                    return;
                }
                if (fingers.flickWasRunning)
                    return;
                if (screen.term !== null && screen.term.hasSelection) {
                    screen.endSelection();
                    return;
                }
                screen.showKeyboard();
                if (screen.term === null)
                    return;
                const at = fingers.mapToItem(screen.term, point.x, point.y);
                // A program with the mouse gets the tap; otherwise it may be a link.
                if (screen.term.mouseTracking) {
                    events.mouse(screen.term, "press", at.x, at.y);
                    events.mouse(screen.term, "release", at.x, at.y);
                    return;
                }
                const link = screen.term.linkUnder(at);
                if (link !== null)
                    screen.term.followLink(link);
            }
            onCanceled: {
                hold.stop();
                screen.letGoOfSelection();
            }

            Timer {
                id: hold

                interval: 450
                onTriggered: screen.beginSelection(fingers.start)
            }

            // Slows to a stop within a second and a half, and draws nothing after that.
            Timer {
                id: flick

                property real speed: 0
                property real last: 0
                property real startedAt: 0

                function begin(velocity) {
                    speed = velocity;
                    startedAt = last = Date.now();
                    start();
                }

                interval: 16
                repeat: true
                onTriggered: {
                    const now = Date.now();
                    events.wheel(screen.term, flick.speed * (now - flick.last));
                    flick.last = now;
                    flick.speed *= 0.95;
                    if (Math.abs(flick.speed) < 0.05 || now - flick.startedAt > 1500)
                        stop();
                }
            }
        }

        // Extends the selection by words, from where it began.
        Rectangle {
            objectName: "terminalSelectionHandle"
            visible: screen.selecting
            x: screen.handleAt.x - width / 2
            y: screen.handleAt.y - height / 2
            width: 36
            height: 36
            radius: 18
            color: Qt.alpha(Theme.palette.color("accent", "#2563eb"), 0.6)

            MultiPointTouchArea {
                anchors.fill: parent
                mouseEnabled: false
                maximumTouchPoints: 1
                // In the parent's coordinates: the handle moves under the finger.
                onUpdated: points => {
                    const at = mapToItem(fingers, points[0].x, points[0].y);
                    screen.extendSelection(Qt.point(at.x, at.y));
                }
            }
        }

        Row {
            objectName: "terminalSelectionMenu"
            visible: screen.selecting || (screen.term !== null && screen.term.hasSelection)
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: 8
            spacing: 4

            MobileButton {
                objectName: "terminalCopy"
                text: qsTr("Copy")
                onClicked: {
                    Shell.setClipboardText(screen.term.selectedText());
                    screen.endSelection();
                }
            }

            MobileButton {
                objectName: "terminalSelectAll"
                text: qsTr("Select All")
                onClicked: {
                    screen.letGoOfSelection();
                    screen.term.selectAll();
                }
            }

            MobileIconButton {
                objectName: "terminalSelectionClose"
                iconName: "x"
                label: qsTr("Close the selection")
                onClicked: screen.endSelection()
            }
        }
    }

    // The keys a soft keyboard lacks, while it is up. None of them takes the focus
    // from the Terminal, which would put the keyboard away.
    Flickable {
        id: keyRow

        objectName: "terminalKeyRow"
        Layout.fillWidth: true
        Layout.preferredHeight: 48
        visible: screen.keysWanted
        contentWidth: keys.width
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.HorizontalFlick
        clip: true

        component RowKey: ToolButton {
            property string name: ""

            objectName: "terminalKey:" + name
            text: name
            implicitWidth: 44
            implicitHeight: 48
            focusPolicy: Qt.NoFocus
        }

        Row {
            id: keys

            RowKey {
                name: "esc"
                onClicked: events.key(screen.term, Qt.Key_Escape)
            }
            Repeater {
                model: screen.mine !== null ? screen.mine.modifiers : []
                delegate: RowKey {
                    required property string modelData

                    name: modelData
                    checkable: false
                    highlighted: screen.mine !== null && screen.mine.held === modelData
                    onClicked: Shell.dispatch("mobileTerminal.modifier", { key: modelData })
                }
            }
            RowKey {
                name: "tab"
                onClicked: events.key(screen.term, Qt.Key_Tab)
            }
            RowKey {
                name: "paste"
                implicitWidth: 56
                onClicked: Shell.dispatch("mobileTerminal.paste")
            }
            RowKey {
                name: "clear"
                implicitWidth: 56
                onClicked: Shell.dispatch("mobileTerminal.clear")
            }
            RowKey {
                name: "up"
                text: "↑"
                onClicked: events.key(screen.term, Qt.Key_Up)
            }
            RowKey {
                name: "down"
                text: "↓"
                onClicked: events.key(screen.term, Qt.Key_Down)
            }
            RowKey {
                name: "left"
                text: "←"
                onClicked: events.key(screen.term, Qt.Key_Left)
            }
            RowKey {
                name: "right"
                text: "→"
                onClicked: events.key(screen.term, Qt.Key_Right)
            }
            Repeater {
                model: ["~", "|", "/", "-"]
                delegate: RowKey {
                    required property string modelData

                    name: modelData
                    onClicked: Shell.dispatch("mobileTerminal.input", { data: modelData })
                }
            }
            RowKey {
                name: "hide"
                icon.name: ""
                text: "⌄"
                Accessible.name: qsTr("Hide the keyboard")
                onClicked: screen.hideKeyboard()
            }
        }
    }

    TerminalContextSheet {
        parent: Overlay.overlay
    }
}
