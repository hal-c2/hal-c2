import QtQuick
import QtQuick.Effects
import HalC2.Shell

// What popovers, menus, palettes and dialogs are drawn on: the overlay
// surface with a strong hairline and one static shadow. Use it as a popup's
// background; ShellPopover and ShellMenu already do. It is solid whatever the
// glass opacity, which thins only the composer: a menu is read over anything.
Item {
    id: surface

    property real radius: Theme.radiusLg
    property color color: Theme.palette.color("surfaceOverlay", "#22262e")

    RectangularShadow {
        anchors.fill: frame
        radius: frame.radius
        offset.y: 8
        blur: 24
        color: Theme.appearance === "light" ? Qt.rgba(0, 0, 0, 0.12) : Qt.rgba(0, 0, 0, 0.5)
    }

    Rectangle {
        id: frame
        objectName: "popoverFrame"

        anchors.fill: parent
        radius: surface.radius
        color: Qt.rgba(surface.color.r, surface.color.g, surface.color.b, 1)
        border.color: Theme.palette.color("borderStrong", "#343a44")
        border.width: 1
    }
}
