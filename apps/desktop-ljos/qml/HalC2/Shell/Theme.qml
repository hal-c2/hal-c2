pragma Singleton
import QtQuick

// Stands in for ThemeStore (desktop-qt/src/ThemeStore.cpp) with no theme.json and no base theme.
QtObject {
    readonly property bool loaded: false
    readonly property bool baseLoaded: false
    readonly property string path: ""
    readonly property string id: ""
    readonly property string name: ""
    readonly property string appearance: "dark"
    readonly property bool followsSystemAppearance: false
    readonly property string lastError: ""
    readonly property color link: "#5aa9ff"
    readonly property real radius: 8
    readonly property string fontUi: ""
    readonly property string fontMono: "monospace"
    readonly property string fontPrompt: fontUi
    readonly property string fontTerminal: fontMono
    readonly property real fontScale: 1
    readonly property int fontSizePrompt: 14
    readonly property int fontSizeCode: 13
    readonly property int fontSizeTerminal: 12
    readonly property real windowOpacity: 1
    readonly property bool windowTransparent: false
    readonly property bool windowBlur: false
    readonly property bool windowLiquidGlass: false
    readonly property bool frameless: true
    // palette.color(role, fallback): the fallback, as with no theme loaded.
    readonly property QtObject palette: QtObject {
        function color(role, fallback) { return fallback; }
    }
    function reload() {}
}
