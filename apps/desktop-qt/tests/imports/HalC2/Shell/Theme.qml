pragma Singleton
import QtQuick

QtObject {
    id: theme

    readonly property QtObject palette: theme
    property real radius: 8
    readonly property string fontUi: ""
    readonly property string fontMono: ""
    property var colors: ({})
    // The frameless window (the header strip is its title bar).
    property bool frameless: false

    function color(role, fallback) {
        return colors[role] ?? fallback;
    }
}
