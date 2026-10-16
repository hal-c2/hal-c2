import QtQuick

// Stands in for ComposerHighlighter (desktop-qt/src/native/ComposerHighlighter.h): highlights nothing.
QtObject {
    property var document: null
    property bool rich: false
    property color markerColor: "transparent"
    property string codeFont: ""
}
