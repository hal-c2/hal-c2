import QtQuick
import QtQuick.Shapes

// A QR code for a phone's camera to read off the screen. `modules` is the
// code's side and `path` its dark modules as an SVG path of unit squares
// (qr::path in src/native/QrCode.h). It is always black on white inside the
// quiet zone a reader wants, whatever the theme: an inverted or tinted code
// may not scan. Each module is a whole number of pixels, as many as bring the
// code near `preferredSide`, fewer when `availableWidth` is narrower, and
// never under `minimumModule`, where a phone at arm's length stops reading it:
// the code overflows a narrower space rather than shrink further.
Rectangle {
    id: code

    property int modules: 0
    property string path: ""
    property real availableWidth: Infinity
    property real preferredSide: 264
    readonly property int minimumModule: 4
    readonly property int quietZone: 4
    readonly property int side: modules + 2 * quietZone
    readonly property int moduleSize: modules > 0 ? Math.max(minimumModule, Math.min(Math.ceil(preferredSide / side), Math.floor(availableWidth / side))) : 0

    implicitWidth: side * moduleSize
    implicitHeight: side * moduleSize
    color: "white"
    Accessible.role: Accessible.Graphic

    Shape {
        x: code.quietZone * code.moduleSize
        y: code.quietZone * code.moduleSize
        width: code.modules * code.moduleSize
        height: code.modules * code.moduleSize

        ShapePath {
            strokeColor: "transparent"
            fillColor: "black"
            scale: Qt.size(code.moduleSize, code.moduleSize)

            PathSvg {
                path: code.path
            }
        }
    }
}
