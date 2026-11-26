import QtQuick

// Stands in for QtQuick's MultiPointTouchArea, which Ljós has from
// hal-c2/ljos-ui f6af256d1 (2026-11-19) on, past the rev desktop-ljos
// pins. TerminalScreen imports HalC2.Shell after QtQuick, so this
// shadows the real one: delete it, and its qmldir line, when the pin
// moves past that commit (#1670). Until then the Terminal's fingers do
// nothing of their own; a mouse goes straight to the Terminal below, as
// the screen intends.
Item {
    property bool mouseEnabled: true
    property int minimumTouchPoints: 0
    property int maximumTouchPoints: 0

    signal pressed(var points)
    signal updated(var points)
    signal released(var points)
    signal canceled(var points)
}
