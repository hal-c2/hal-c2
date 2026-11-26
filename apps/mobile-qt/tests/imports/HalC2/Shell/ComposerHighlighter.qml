import QtQuick

// ComposerHighlighter (src/native/ComposerHighlighter.h) without the drawing.
QtObject {
    property var document: null
    property bool rich: false
    property color markerColor: "transparent"
    property string codeFont: ""
}
