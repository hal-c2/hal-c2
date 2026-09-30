import QtQuick
import HalC2.Shell

// The thread's terminals for an XR panel: the drawer's shown group, mirrored
// (TerminalSplits.mirror), so the drawer keeps their size and the keyboard.
Rectangle {
    color: Theme.palette.color("canvas", "#09090b")

    TerminalSplits {
        anchors.fill: parent
        visible: Terminals.available
        mirror: true
        group: Terminals.activeGroup
    }

    Text {
        anchors.centerIn: parent
        visible: !Terminals.available
        text: qsTr("No terminal in this thread")
        color: Theme.palette.color("textMuted", "#8b8b93")
        font.pixelSize: 20
    }
}
