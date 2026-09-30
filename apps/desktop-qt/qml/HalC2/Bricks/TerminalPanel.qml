import QtQuick
import HalC2.Shell

// The right panel's terminal tabs: the shown `terminal:<group>` tab's
// terminals side by side or stacked (TerminalSplits), from the `Terminals`
// controller, with its split buttons. Every panel tab's terminals stay made
// while another tab shows, so each keeps its screen.
//
//   TerminalPanel { anchors.fill: parent; tabId: panel.activeId }
Rectangle {
    id: root

    // Unused: the terminals are the `Terminals` singleton's.
    property var source: null
    // The panel's active tab; a terminal one picks the group shown.
    property string tabId: (Shell.state.panel ?? null)?.activeId ?? ""
    // The group shown, kept while another tab shows.
    property string group: ""

    readonly property int groupSize: Terminals.groupSizes[root.group] ?? 1
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")

    function focusTerminal(terminalId) {
        const terminal = splits.terminalOf(terminalId);
        if (terminal !== null && root.visible)
            terminal.forceActiveFocus();
    }

    objectName: "terminalPanel"
    color: Theme.palette.color("canvas", "#09090b")
    onTabIdChanged: if (tabId.startsWith("terminal:"))
        root.group = tabId.slice("terminal:".length)
    Component.onCompleted: if (tabId.startsWith("terminal:"))
        root.group = tabId.slice("terminal:".length)

    Connections {
        target: Terminals
        function onFocusRequested(terminalId) {
            Qt.callLater(root.focusTerminal, terminalId);
        }
    }

    Row {
        id: strip

        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 4
        anchors.rightMargin: 6
        height: 26
        spacing: 2

        ShellButton {
            objectName: "terminalPanelSplit"
            subtle: true
            implicitWidth: 24
            implicitHeight: 24
            iconName: "square-split-horizontal"
            iconSize: 13
            iconTint: root.muted
            focusPolicy: Qt.NoFocus
            enabled: root.groupSize < 4
            Accessible.name: enabled ? qsTr("Split Terminal Horizontally") : qsTr("Split Terminal Horizontally (max 4 per group)")
            onClicked: Shell.dispatch("terminal.split", { terminalId: splits.currentTerminal() })
        }

        ShellButton {
            objectName: "terminalPanelSplitVertical"
            subtle: true
            implicitWidth: 24
            implicitHeight: 24
            iconName: "square-split-vertical"
            iconSize: 13
            iconTint: root.muted
            focusPolicy: Qt.NoFocus
            enabled: root.groupSize < 4
            Accessible.name: enabled ? qsTr("Split Terminal Vertically") : qsTr("Split Terminal Vertically (max 4 per group)")
            onClicked: Shell.dispatch("terminal.splitVertical", { terminalId: splits.currentTerminal() })
        }
    }

    TerminalSplits {
        id: splits

        anchors.top: strip.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.topMargin: 2
        panel: true
        group: root.group
        background: root.color
    }
}
