import QtQuick
import Ghostty
import HalC2.Shell

// A terminal's right-click menu: opening or copying the link under the
// pointer, the selection's actions, off until something is selected, and Paste. Adding to
// chat is only offered where there is a draft to add to (`addToChat` set).
//
//   TapHandler { acceptedButtons: Qt.RightButton; onTapped: point => menu.popup(point.position.x, point.position.y) }
//   TerminalMenu { id: menu; terminal: screen }
//
// The same from the keyboard, and the keys a shell's line editor has no chord
// for: Ctrl+V pastes, and Ctrl+C (or Ctrl+Insert) copies a selection and stays
// the shell's without one; on macOS Cmd+V and Cmd+C, Cmd+K clears, Cmd+Backspace
// deletes to the line's start, and Ctrl is always the shell's. Everything else
// goes on to the Terminal, which encodes it.
//
//   Terminal { Keys.onPressed: event => menu.keyPressed(event) }
ShellMenu {
    id: menu

    // The Ghostty Terminal it acts on.
    required property Terminal terminal
    // Adds the selection to the draft; null where there is none.
    property var addToChat: null
    // The link under the pointer ({kind: "url"|"path", text}), set before
    // the menu opens; null for none. `follow` opens one.
    property var link: null
    property var follow: link => {}

    // The platform whose keys apply, as Qt.platform.os names it.
    property string platform: Qt.platform.os
    readonly property bool mac: platform === "osx" || platform === "macos"

    // What a chord of a shell's line editor sends, or "" for any other. Qt
    // calls macOS's Cmd Control, and its Ctrl Meta.
    function lineEditorKeys(modifiers, key) {
        const left = key === Qt.Key_Left;
        const arrow = left || key === Qt.Key_Right;
        const word = left ? "\x1bb" : "\x1bf";
        if (!menu.mac)
            return arrow && (modifiers === Qt.ControlModifier || modifiers === Qt.AltModifier) ? word : "";
        if (modifiers === Qt.AltModifier)
            return arrow ? word : "";
        if (modifiers !== Qt.ControlModifier)
            return "";
        if (arrow)
            return left ? "\x01" : "\x05";
        return key === Qt.Key_K ? "\x0c" : key === Qt.Key_Backspace ? "\x15" : "";
    }

    // A chord that types a character (AltGr, which Windows reports as Ctrl+Alt,
    // or macOS's Option) rather than asking for something.
    function typesCharacter(modifiers, text) {
        if (text.length === 0 || text.charCodeAt(0) < 0x20 || text === "\x7f")
            return false;
        const held = modifiers & ~Qt.ShiftModifier;
        return menu.mac ? held === Qt.AltModifier : (held & Qt.GroupSwitchModifier) !== 0 || held === (Qt.ControlModifier | Qt.AltModifier);
    }

    function send(data, event) {
        menu.terminal.scrollToBottom();
        menu.terminal.input(data);
        event.accepted = true;
    }

    // Copies the selection; says so in the terminal when it did not reach the clipboard.
    function copySelection() {
        const copied = menu.terminal.copy();
        if (!copied)
            menu.terminal.session.report(qsTr("Unable to copy terminal selection"));
        return copied;
    }

    function keyPressed(event) {
        event.accepted = false;
        const modifiers = event.modifiers & ~Qt.KeypadModifier;
        const key = event.key;
        const lineEditor = menu.lineEditorKeys(modifiers, key);
        if (lineEditor.length > 0) {
            menu.send(lineEditor, event);
        } else if (menu.typesCharacter(modifiers, event.text)) {
            menu.send(event.text, event);
        } else if (modifiers !== Qt.ControlModifier) {
            return;
        } else if (key === Qt.Key_V) {
            menu.terminal.paste(Shell.clipboardText());
            event.accepted = true;
        } else if ((key === Qt.Key_C || key === Qt.Key_Insert) && menu.terminal.hasSelection) {
            // The next Ctrl+C is the shell's; Cmd+C leaves the selection be, and
            // so does a copy that failed, to try again.
            if (menu.copySelection() && key === Qt.Key_C && !menu.mac)
                menu.terminal.clearSelection();
            event.accepted = true;
        } else if (menu.mac) {
            // Cmd is the app's: it never reaches the program.
            event.accepted = true;
        }
    }

    ShellMenuItem {
        objectName: "terminalOpenLink"
        text: menu.link?.kind === "path" ? qsTr("Open file") : qsTr("Open link")
        visible: menu.link !== null
        height: visible ? implicitHeight : 0
        onTriggered: menu.follow(menu.link)
    }
    ShellMenuItem {
        objectName: "terminalCopyLink"
        text: menu.link?.kind === "path" ? qsTr("Copy path") : qsTr("Copy link")
        visible: menu.link !== null
        height: visible ? implicitHeight : 0
        onTriggered: Shell.setClipboardText(menu.link.text)
    }
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
        onTriggered: menu.copySelection()
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
