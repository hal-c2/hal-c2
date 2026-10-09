import QtQuick

// qml-ghostty's Terminal, as an inert item: the bricks only need its names to
// compile and lay out; nothing here draws or talks to a shell.
FocusScope {
    property real padding: 0
    property font font
    property color backgroundColor
    property color foregroundColor
    property color cursorColor
    property color selectionColor
    property int columns: 80
    property int rows: 24
    property real cellWidth: 8
    property real cellHeight: 16
    property real scrollOffset: 0
    property string workingDirectory: ""
    property bool hasSelection: false

    signal input(string data)
    signal resized(int columns, int rows)

    function restore(history) {
    }
    function write(data) {
    }
    function reset() {
    }
    function text() {
        return "";
    }
    function selectedText() {
        return "";
    }
    function clearSelection() {
    }
}
