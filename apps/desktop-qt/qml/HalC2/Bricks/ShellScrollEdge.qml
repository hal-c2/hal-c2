import QtQuick
import HalC2.Shell

// The sign that a list goes on: a thin, still scrollbar at the list's right
// edge while its rows are taller than it, as long as the share that shows and
// placed where it is. Declare it inside the list with `target: <the list>`.
// It lies in the rows' right padding, so it dims no text, and it takes no
// input: the wheel and the keys scroll. Nothing animates.
Item {
    id: edges

    required property Flickable target
    readonly property bool scrolls: target.contentHeight > target.height
    readonly property bool moreAbove: scrolls && !target.atYBeginning
    readonly property bool moreBelow: scrolls && !target.atYEnd

    // On the list itself, not its content, so it stays put as the list scrolls.
    parent: target
    anchors.fill: parent
    z: 1

    Rectangle {
        id: thumb

        objectName: "scrollThumb"

        readonly property real track: edges.height - 2 * Theme.space.xxs
        readonly property real shown: Math.min(1, edges.target.visibleArea.heightRatio)
        // How far down the list the view is, 0 at the top and 1 at the end.
        readonly property real progress: edges.target.atYEnd ? 1 : shown >= 1 ? 0 : Math.max(0, Math.min(1, edges.target.visibleArea.yPosition / (1 - shown)))

        visible: edges.scrolls
        x: edges.width - width - Theme.space.xxs
        y: Theme.space.xxs + (track - height) * progress
        width: Theme.space.xs
        // Never shorter than a small control, so a long list's still shows.
        height: Math.max(Theme.control.sm, track * shown)
        radius: Theme.radiusPill
        color: Theme.palette.color("borderStrong", "#343a44")
    }
}
