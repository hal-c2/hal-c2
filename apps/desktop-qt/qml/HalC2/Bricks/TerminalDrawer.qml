pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// The thread's terminal drawer: a tab per split group and the shown group's
// terminals side by side or stacked (TerminalSplits), fed by the `Terminals`
// controller's sessions on the MC. Open flag, height, groups and the active
// one are the controller's; dragging the top edge hands the height back with
// terminal.resize. The right panel's terminal tabs are not the drawer's. Not
// animated: every frame of it would relayout the thread above (see RightPanel).
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
    // hands focus back, as the web app returns it to its composer.
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

    readonly property int groupSize: Terminals.groupSizes[Terminals.activeGroup] ?? 1

    function activeTerminal() {
        return stack.terminalOf(Terminals.activeTerminalId);
    }

    function applyFocus(terminalId) {
        const terminal = terminalId ? stack.terminalOf(terminalId) : drawer.activeTerminal();
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
        // Opened, a terminal added, split, selected or closed: the keyboard
        // follows, when the terminal is the drawer's.
        function onFocusRequested(terminalId) {
            Qt.callLater(drawer.applyFocus, terminalId);
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

    // The web app clamps the same way: never shorter than a few rows, never
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

            // One tab per group of the drawer's, on its first terminal.
            delegate: ShellButton {
                id: tab

                required property string terminalId
                required property string label
                required property bool busy
                required property string group
                required property bool panel
                required property int slot
                required property int span

                objectName: "terminalTab"
                visible: !tab.panel && tab.slot === 0
                subtle: true
                checked: tab.group === Terminals.activeGroup
                implicitHeight: 24
                iconName: "terminal"
                iconSize: 13
                text: tab.span > 1 ? qsTr("%1 +%2").arg(tab.label).arg(tab.span - 1) : tab.label
                font.pixelSize: Math.round(12 * Theme.fontScale)
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
            objectName: "terminalSplit"
            subtle: true
            implicitWidth: 24
            implicitHeight: 24
            iconName: "square-split-horizontal"
            iconSize: 13
            iconTint: drawer.muted
            focusPolicy: Qt.NoFocus
            enabled: drawer.groupSize < 4
            Accessible.name: enabled ? qsTr("Split Terminal Horizontally") : qsTr("Split Terminal Horizontally (max 4 per group)")
            onClicked: Shell.dispatch("terminal.split", { terminalId: Terminals.activeTerminalId })
        }

        ShellButton {
            objectName: "terminalSplitVertical"
            subtle: true
            implicitWidth: 24
            implicitHeight: 24
            iconName: "square-split-vertical"
            iconSize: 13
            iconTint: drawer.muted
            focusPolicy: Qt.NoFocus
            enabled: drawer.groupSize < 4
            Accessible.name: enabled ? qsTr("Split Terminal Vertically") : qsTr("Split Terminal Vertically (max 4 per group)")
            onClicked: Shell.dispatch("terminal.splitVertical", { terminalId: Terminals.activeTerminalId })
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
            onClicked: Shell.dispatch("terminal.close", { terminalId: Terminals.activeTerminalId })
        }
    }

    TerminalSplits {
        id: stack

        anchors.top: strip.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.topMargin: 2
        anchors.leftMargin: drawer.inset
        anchors.rightMargin: drawer.inset
        anchors.bottomMargin: drawer.inset
        panel: false
        group: Terminals.activeGroup
        background: drawer.background
        foreground: drawer.foreground
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

    // The drag edge sits over the top of the drawer, like the web app's own
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
