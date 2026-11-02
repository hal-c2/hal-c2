import QtQuick
import HalC2.Shell

// A text's right-click menu: Cut, Copy, Paste and Select All, or Copy and
// Select All on read-only text, as Qt's own TextArea menu offers. `paste`
// replaces the editor's paste for one that does more (the composer attaches
// copied pictures and files).
//
//   TapHandler { acceptedButtons: Qt.RightButton
//                onTapped: point => menu.openAt(point.position.x, point.position.y) }
//   TextEditMenu { id: menu; editor: field }
//
// On a TextArea or TextField, a MouseArea taking the right button instead
// keeps Qt's own menu from opening too; a TapHandler does not. The secondary
// button only: a finger has none, and touch platforms have their own menu.
// It stands in for an editor's own menu where that menu falls short: a
// TextEdit has none, and the composer's Paste does more than a TextArea's.
ShellMenu {
    id: menu

    // The TextEdit, TextArea or TextField it acts on.
    property Item editor: null
    // Pastes into the editor; null pastes the clipboard's text.
    property var paste: null

    readonly property bool editable: editor !== null && !editor.readOnly && editor.enabled
    // The selection when the menu opened: the menu takes the keyboard, and
    // an editor that loses it may drop its selection.
    property int start: 0
    property int end: 0
    property string selected: ""

    // Opens at `x`, `y` in the editor's coordinates.
    function openAt(x, y) {
        start = editor.selectionStart;
        end = editor.selectionEnd;
        selected = editor.selectedText;
        popup(editor, x, y);
    }

    // The Menu key and Shift+F10 open it at the cursor; true when they did.
    function keyPressed(event) {
        if (event.key !== Qt.Key_Menu && !(event.key === Qt.Key_F10 && event.modifiers === Qt.ShiftModifier))
            return false;
        const caret = editor.cursorRectangle;
        openAt(caret.x, caret.y + caret.height);
        return true;
    }

    // Rich text separates its paragraphs with U+2029.
    function copy() {
        Shell.setClipboardText(selected.replace(/[\u2028\u2029]/g, "\n"));
    }

    // Select All waits for the menu to close: an editor that loses the
    // keyboard drops its selection, and the menu gives it back as it goes.
    property bool selectsAll: false
    onClosed: {
        if (!selectsAll)
            return;
        selectsAll = false;
        editor.forceActiveFocus();
        editor.selectAll();
    }

    function restore() {
        editor.forceActiveFocus();
        editor.select(start, end);
    }

    ShellMenuItem {
        objectName: "cutText"
        text: qsTr("Cut")
        visible: menu.editable
        height: visible ? implicitHeight : 0
        enabled: menu.selected.length > 0
        onTriggered: {
            menu.copy();
            menu.restore();
            menu.editor.remove(menu.start, menu.end);
        }
    }
    ShellMenuItem {
        objectName: "copyText"
        text: qsTr("Copy")
        enabled: menu.selected.length > 0
        onTriggered: menu.copy()
    }
    ShellMenuItem {
        objectName: "pasteText"
        text: qsTr("Paste")
        visible: menu.editable
        height: visible ? implicitHeight : 0
        onTriggered: {
            menu.restore();
            if (menu.paste !== null)
                menu.paste();
            else
                menu.editor.paste();
        }
    }
    ShellMenuItem {
        objectName: "selectAllText"
        text: qsTr("Select All")
        enabled: menu.editor !== null && menu.editor.text.length > 0
        onTriggered: menu.selectsAll = true
    }
}
