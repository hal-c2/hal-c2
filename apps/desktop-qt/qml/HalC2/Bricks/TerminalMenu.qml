import QtQuick
import HalC2.Shell

// A terminal's right-click menu, as the web's terminalContextMenuItems: the
// selection's actions, off until something is selected, and Paste. Adding to
// chat is only offered where there is a draft to add to (`addToChat` set).
//
//   TapHandler { acceptedButtons: Qt.RightButton; onTapped: point => menu.popup(point.position.x, point.position.y) }
//   TerminalMenu { id: menu; terminal: screen }
ShellMenu {
    id: menu

    // The Ghostty Terminal it acts on.
    required property Item terminal
    // Adds the selection to the draft; null where there is none.
    property var addToChat: null

    ShellMenuItem {
        objectName: "terminalAddToChat"
        text: qsTr("Add to chat")
        visible: menu.addToChat !== null
        height: visible ? implicitHeight : 0
        enabled: menu.terminal.hasSelection
        onTriggered: menu.addToChat()
    }
    ShellMenuItem {
        objectName: "terminalCopy"
        text: qsTr("Copy")
        enabled: menu.terminal.hasSelection
        onTriggered: menu.terminal.copy()
    }
    ShellMenuItem {
        objectName: "terminalPaste"
        text: qsTr("Paste")
        onTriggered: {
            menu.terminal.paste(Shell.clipboardText());
            menu.terminal.forceActiveFocus();
        }
    }
}
