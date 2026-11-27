import QtQuick

// CodeHighlighter (src/native/CodeHighlighter.h) without the colours.
QtObject {
    property var document: null
    property string language: ""
    property string path: ""
    property color background: "transparent"
    property bool streaming: false
    readonly property bool coloured: false
}
