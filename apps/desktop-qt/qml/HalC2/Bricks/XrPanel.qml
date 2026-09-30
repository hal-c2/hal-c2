import QtQuick
import QtQuick3D
import QtQuick3D.Xr
import HalC2.Shell

// A flat panel in the XR workspace (XrWorkspace) facing the user: turned
// `angle` degrees to their left and `elevation` degrees up, `distance` ahead,
// `width` by `height` (scene units are centimetres). Its children are bricks
// that fill it as they would a window (anchors.fill: parent), drawn at
// `density` pixels per centimetre.
Node {
    id: panel

    property real angle: 0
    property real elevation: 0
    property real distance: 150
    property real width: 120
    property real height: 75
    // 1280 pixels across the stock 1.2 m thread panel.
    property real density: 1280 / 120
    property color color: Theme.palette.color("chrome", "#0b0b0d")
    default property alias content: surface.data

    eulerRotation.y: angle

    Node {
        eulerRotation.x: panel.elevation

        XrItem {
            width: panel.width
            height: panel.height
            x: -width / 2
            y: height / 2
            z: -panel.distance
            color: panel.color
            contentItem: Item {
                id: surface

                width: panel.width * panel.density
                height: panel.height * panel.density
            }
        }
    }
}
