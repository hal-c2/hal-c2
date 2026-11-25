pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// The thread's terminal drawer: the shown group's terminals side by side or
// stacked (TerminalSplits), fed by the `Terminals` controller's sessions on the
// MC. Its actions sit above the terminals; with more than one terminal, a
// list beside the terminals names each group under them. Open flag, height, groups and the active
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
    // hands focus back.
    property Item focusBefore: null
    property bool hadFocus: false
    readonly property bool bodyFocused: stack.activeFocus

    readonly property color background: Theme.palette.color("canvas", "#09090b")
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    // Ink, not the `muted` surface: inactive tabs are muted text.
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    // The toolbar's icons are the text colour at 90%.
    readonly property color toolbarInk: Theme.palette.color("inkSecondary", "#b8bdc7")
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

    // Never shorter than a few rows, never
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

    readonly property bool listShown: Terminals.drawerCount > 1

    // The terminals' list, under the actions.
    Flickable {
        id: terminalList

        objectName: "terminalList"
        visible: drawer.listShown
        anchors.top: actions.bottom
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.topMargin: 2
        anchors.rightMargin: Math.max(Theme.space.sm, drawer.inset)
        anchors.bottomMargin: drawer.inset
        width: 180
        clip: true
        contentHeight: listColumn.height
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: listColumn

            width: terminalList.width
            spacing: 2

            Repeater {
                model: Terminals.tabs

                // One entry per group of the drawer's, on its first terminal.
                delegate: Column {
                    id: entry

                    required property string terminalId
                    required property string label
                    required property bool busy
                    required property string group
                    required property bool panel
                    required property int slot
                    required property int span
                    required property bool vertical

                    visible: !entry.panel && entry.slot === 0
                    width: listColumn.width

                    ShellButton {
                        objectName: "terminalGroupLabel"
                        subtle: true
                        width: parent.width
                        implicitHeight: 20
                        text: qsTr("%1 (%2)").arg(entry.span <= 1 ? qsTr("Single") : entry.vertical ? qsTr("Stacked") : qsTr("Side by side")).arg(entry.span)
                        font.pixelSize: Theme.type.caption.size
                        tint: drawer.muted
                        focusPolicy: Qt.NoFocus
                        onClicked: Shell.dispatch("terminal.select", { terminalId: entry.terminalId })
                    }

                    ShellButton {
                        id: tab

                        objectName: "terminalTab"
                        subtle: true
                        width: parent.width
                        checked: entry.group === Terminals.activeGroup
                        implicitHeight: 24
                        iconName: "terminal"
                        iconSize: 13
                        text: entry.span > 1 ? qsTr("%1 +%2").arg(entry.label).arg(entry.span - 1) : entry.label
                        font.pixelSize: Theme.type.meta.size
                        tint: tab.checked ? drawer.foreground : drawer.muted
                        focusPolicy: Qt.NoFocus
                        Accessible.name: entry.busy ? qsTr("%1, running").arg(entry.label) : entry.label
                        onClicked: Shell.dispatch("terminal.select", { terminalId: entry.terminalId })
                    }
                }
            }
        }
    }

    TerminalSplits {
        id: stack

        objectName: "terminalDrawerSplits"
        // Under the actions, so they never cover the first line; beside the
        // list, the actions sit over the list instead.
        anchors.top: drawer.listShown ? edgeLine.bottom : actions.bottom
        anchors.topMargin: drawer.listShown ? 0 : 2
        anchors.left: parent.left
        anchors.right: drawer.listShown ? terminalList.left : parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: drawer.inset
        anchors.rightMargin: drawer.listShown ? Theme.space.sm : drawer.inset
        anchors.bottomMargin: drawer.inset
        panel: false
        group: Terminals.activeGroup
        background: drawer.background
        foreground: drawer.foreground
    }

    RowLayout {
        id: actions

        objectName: "terminalDrawerActions"
        anchors.top: edgeLine.bottom
        anchors.right: parent.right
        anchors.topMargin: 4
        anchors.rightMargin: Math.max(Theme.space.sm, drawer.inset)
        height: 26
        spacing: 2

        ShellButton {
            objectName: "terminalSplit"
            subtle: true
            implicitWidth: 24
            implicitHeight: 24
            iconName: "square-split-horizontal"
            iconSize: 13
            iconTint: drawer.toolbarInk
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
            iconTint: drawer.toolbarInk
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
            iconTint: drawer.toolbarInk
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
            iconTint: drawer.toolbarInk
            focusPolicy: Qt.NoFocus
            Accessible.name: qsTr("Close terminal")
            onClicked: Shell.dispatch("terminal.close", { terminalId: Terminals.activeTerminalId })
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

    // The drag edge sits over the top of the drawer.
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
