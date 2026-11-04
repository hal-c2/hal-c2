pragma Singleton
import QtQuick

QtObject {
    id: theme

    readonly property QtObject palette: theme
    property color link: "#60a5fa"
    property string appearance: "dark"
    // The shell's theme file: none unless a test says so.
    property bool loaded: false
    property string name: ""
    property string path: "/config/theme.json"
    property bool followsSystemAppearance: false
    property string lastError: ""
    property real radius: 8
    // The scale ThemeStore derives from radius.
    readonly property real radiusXs: Math.round(radius * 0.5)
    readonly property real radiusSm: Math.round(radius * 0.75)
    readonly property real radiusMd: radius
    readonly property real radiusLg: Math.round(radius * 1.5)
    readonly property real radiusXl: Math.round(radius * 2)
    readonly property real radiusPill: 9999
    property bool monospace: false
    readonly property QtObject type: QtObject {
        function step(size, lineHeight, weight) {
            return {
                size: Math.round(size * theme.fontScale),
                lineHeight: Math.round(lineHeight * theme.fontScale) + (theme.monospace ? 2 : 0),
                weight: weight
            };
        }
        readonly property var caption: step(11, 16, 500)
        readonly property var meta: step(12, 16, 400)
        readonly property var body: step(13, 18, 400)
        readonly property var prose: step(14, 22, 400)
        readonly property var title: step(16, 22, 600)
        readonly property var display: theme.monospace ? ({
                size: Math.round(22 * theme.fontScale),
                lineHeight: Math.round(28 * theme.fontScale),
                weight: 600
            }) : step(24, 30, 600)
    }
    readonly property QtObject space: QtObject {
        readonly property int xxs: 2
        readonly property int xs: 4
        readonly property int sm: 8
        readonly property int md: 12
        readonly property int lg: 16
        readonly property int xl: 24
        readonly property int xxl: 32
    }
    readonly property QtObject control: QtObject {
        readonly property int sm: 24
        readonly property int md: 28
        readonly property int lg: 32
        readonly property int xl: 36
    }
    readonly property QtObject icon: QtObject {
        readonly property int sm: 12
        readonly property int md: 16
        readonly property int lg: 20
        readonly property int xl: 24
        function stroke(size) {
            return size <= 12 ? 2 : size <= 16 ? 1.75 : 1.5;
        }
    }
    readonly property string fontUi: ""
    property string fontMono: ""
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

    // Roles under two names, as ThemeStore reads them.
    readonly property var renames: ({
            ink: "text",
            text: "ink",
            inkTertiary: "textMuted",
            textMuted: "inkTertiary",
            destructive: "error",
            error: "destructive",
            popover: "surfaceOverlay",
            surfaceOverlay: "popover"
        })

    function color(role, fallback) {
        return colors[role] ?? colors[renames[role]] ?? fallback;
    }
}
