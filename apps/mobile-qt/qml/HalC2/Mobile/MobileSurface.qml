import QtQuick
import HalC2.Shell

// What the phone layout's sheet and dialog sit on: the surface the bricks' own
// dialogs use (ConfirmDialog), over the canvas. The Theme may thin that
// surface (Appearance's glass), and a sheet as large as the screen it covers
// is unreadable with the conversation showing through.
Rectangle {
    color: Theme.palette.color("canvas", "#0b0b0d")
    radius: Math.min(Theme.radius, 16)

    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        color: Theme.palette.color("surfaceOverlay", "#18181b")
        border.color: Theme.palette.color("border", "#27272a")
        border.width: 1
    }
}
