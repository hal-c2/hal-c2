pragma Singleton
import QtQuick

QtObject {
    id: theme

    readonly property QtObject palette: theme
    property color link: "#60a5fa"
    property string appearance: "dark"
    property real radius: 8
    readonly property string fontUi: ""
    readonly property string fontMono: ""
    readonly property string fontPrompt: ""
    readonly property string fontTerminal: ""
    property real fontScale: 1
    property int fontSizePrompt: 14
    property int fontSizeCode: 13
    property int fontSizeTerminal: 12
    property var colors: ({})
    // The frameless window (the header strip is its title bar).
    property bool frameless: false
    property real windowOpacity: 1
    property bool windowTransparent: false

    function color(role, fallback) {
        return colors[role] ?? fallback;
    }
}
