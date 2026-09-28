import QtQuick
import QtQuick.Layouts
import Ghostty
import HalC2.Shell

// The thread's terminal drawer, drawn by qml-ghostty's Terminal: a tab per
// terminal and one Terminal item per tab, fed by the `Terminals` controller's
// sessions on the node. Open flag, height, tabs and the active one are the
// controller's; dragging the top edge hands the height back with
// terminal.resize. Not animated: every frame of it would relayout the thread
// above (see RightPanel).
Item {
    id: drawer

    readonly property bool available: Terminals.available
    readonly property bool open: available && Terminals.open
    readonly property int minimumHeight: 180

    // The drawer's corner radius, for a rice that cards it.
    property real radius: 0

    // The height while the edge is dragged; -1 when the controller's is shown.
    property int localHeight: -1

    // What had the keyboard before the drawer took it (usually the composer),
    // and whether the drawer still held it when it last was open: closing
    // hands focus back, as the page returns it to its composer.
    property Item focusBefore: null
    property bool hadFocus: false
    readonly property bool bodyFocused: stack.activeFocus

    readonly property color background: Theme.palette.color("canvas", "#09090b")
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("muted", "#a1a1aa")
    readonly property color border: Theme.palette.color("border", "#27272a")
    // Keeps the square Terminal inside a carded drawer's rounded corners.
    readonly property real inset: Math.ceil(radius * 0.3)

    function focusTerminal() {
        if (!drawer.available) return;
        if (drawer.open) drawer.applyFocus();
        else Shell.dispatch("terminal.toggle");
    }

    function activeTerminal() {
        for (let i = 0; i < terminals.count; ++i) {
            const item = terminals.itemAt(i);
            if (item !== null && item.terminalId === Terminals.activeTerminalId) return item;
        }
        return null;
    }

    function applyFocus() {
        const terminal = drawer.activeTerminal();
        if (!drawer.open || terminal === null) return;
        const previous = drawer.Window.activeFocusItem;
        if (previous !== null && !drawer.isInside(previous)) drawer.focusBefore = previous;
        terminal.forceActiveFocus();
    }

    function isInside(item) {
        for (let node = item; node !== null; node = node.parent) {
            if (node === drawer) return true;
        }
        return false;
    }

    Connections {
        target: Terminals
        // Opened, a terminal added, selected or closed: the keyboard follows.
        function onFocusRequested() {
            Qt.callLater(drawer.applyFocus);
        }
    }

    onOpenChanged: {
        if (!drawer.open && drawer.hadFocus) {
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

    implicitHeight: open ? clampHeight(localHeight >= 0 ? localHeight : Terminals.height) : 0
    visible: open

    Rectangle {
        anchors.fill: parent
        radius: drawer.radius
        color: drawer.background
    }

    // The hairline over the drawer; a carded drawer has the card's edge instead.
    Rectangle {
        id: edgeLine
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: drawer.radius > 0 ? 0 : 1
        visible: height > 0
        color: drawer.border
    }

    RowLayout {
        id: strip

        anchors.top: edgeLine.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: 4
        anchors.leftMargin: Math.max(6, drawer.inset)
        anchors.rightMargin: Math.max(6, drawer.inset)
        height: 26
        spacing: 2

        Repeater {
            model: Terminals.tabs

            delegate: ShellButton {
                id: tab

                required property string terminalId
                required property string label
                required property bool busy

                objectName: "terminalTab"
                subtle: true
                checked: tab.terminalId === Terminals.activeTerminalId
                implicitHeight: 24
                iconName: "terminal"
                iconSize: 13
                text: tab.label
                font.pixelSize: 12
                tint: tab.checked ? drawer.foreground : drawer.muted
                focusPolicy: Qt.NoFocus
                Layout.maximumWidth: 180
                Accessible.name: tab.busy ? qsTr("%1, running").arg(tab.label) : tab.label
                onClicked: Shell.dispatch("terminal.select", { terminalId: tab.terminalId })
            }
        }

        Item {
            Layout.fillWidth: true
        }

        ShellButton {
            objectName: "terminalNew"
            subtle: true
            implicitWidth: 24
            implicitHeight: 24
            iconName: "plus"
            iconTint: drawer.muted
            focusPolicy: Qt.NoFocus
            enabled: Terminals.tabs.count < 6
            Accessible.name: qsTr("New terminal")
            onClicked: Shell.dispatch("terminal.new")
        }

        ShellButton {
            objectName: "terminalClose"
            subtle: true
            implicitWidth: 24
            implicitHeight: 24
            iconName: "x"
            iconTint: drawer.muted
            focusPolicy: Qt.NoFocus
            Accessible.name: qsTr("Close terminal")
            onClicked: Shell.dispatch("terminal.close")
        }
    }

    FocusScope {
        id: stack

        anchors.top: strip.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.topMargin: 2
        anchors.leftMargin: drawer.inset
        anchors.rightMargin: drawer.inset
        anchors.bottomMargin: drawer.inset

        // One Terminal per tab, kept while its tab lives so switching tabs
        // keeps each screen and its scrollback.
        Repeater {
            id: terminals

            model: Terminals.tabs

            delegate: Terminal {
                id: terminal

                required property string terminalId
                required property QtObject session

                objectName: "HalC2Terminal"
                anchors.fill: parent
                visible: terminal.terminalId === Terminals.activeTerminalId
                focus: visible
                padding: 6
                font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
                font.pixelSize: 12
                backgroundColor: drawer.background
                foregroundColor: drawer.foreground
                cursorColor: drawer.foreground
                selectionColor: Qt.alpha(Theme.palette.color("accent", "#2563eb"), 0.35)

                onInput: data => terminal.session.write(data)
                // Only a laid-out Terminal knows its grid; the first pass is 1x1.
                onResized: (columns, rows) => {
                    if (terminal.width > 0 && terminal.height > 0)
                        terminal.session.resize(columns, rows);
                }
                Component.onCompleted: {
                    terminal.restore(terminal.session.transcript());
                    if (terminal.width > 0 && terminal.height > 0)
                        terminal.session.resize(terminal.columns, terminal.rows);
                }

                Connections {
                    target: terminal.session
                    function onOutput(data) {
                        terminal.write(data);
                    }
                    function onReplaced(history) {
                        terminal.reset();
                        terminal.restore(history);
                    }
                }
            }
        }
    }

    // While a terminal has the keyboard; the window's own shortcuts stand
    // down there (ShellWindow).
    Shortcut {
        sequence: "Ctrl+N"
        enabled: drawer.bodyFocused
        onActivated: Shell.dispatch("terminal.new")
    }
    Shortcut {
        sequence: "Ctrl+W"
        enabled: drawer.bodyFocused
        onActivated: Shell.dispatch("terminal.close")
    }

    // The drag edge sits over the top of the drawer, like the page's own
    // handle does.
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
                } else {
                    if (drawer.localHeight !== drawer.clampHeight(Terminals.height))
                        Shell.dispatch("terminal.resize", { height: drawer.localHeight });
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
