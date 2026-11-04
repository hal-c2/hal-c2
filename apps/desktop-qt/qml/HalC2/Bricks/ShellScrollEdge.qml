import QtQuick
import HalC2.Shell

// The hint that a list goes on: a static fade at its top and bottom edges,
// shown at an edge while content continues past it. Declare it inside the
// list with `target: <the list>`. It draws in `color`, the surface the list
// sits on (the popover surface by default), and takes no input. Nothing
// animates: an edge shows or hides as the scroll position crosses it.
Item {
    id: edges

    required property Flickable target
    property color color: Theme.palette.color("surfaceOverlay", "#22262e")
    property real size: Theme.space.lg
    readonly property bool moreAbove: target.contentHeight > target.height && !target.atYBeginning
    readonly property bool moreBelow: target.contentHeight > target.height && !target.atYEnd

    // On the list itself, not its content, so it stays put as the list scrolls.
    parent: target
    anchors.fill: parent
    z: 1

    Rectangle {
        objectName: "scrollEdgeTop"
        visible: edges.moreAbove
        width: parent.width
        height: edges.size
        gradient: Gradient {
            GradientStop {
                position: 0
                color: Qt.rgba(edges.color.r, edges.color.g, edges.color.b, 1)
            }
            GradientStop {
                position: 1
                color: Qt.rgba(edges.color.r, edges.color.g, edges.color.b, 0)
            }
        }
    }

    Rectangle {
        objectName: "scrollEdgeBottom"
        visible: edges.moreBelow
        y: parent.height - height
        width: parent.width
        height: edges.size
        gradient: Gradient {
            GradientStop {
                position: 0
                color: Qt.rgba(edges.color.r, edges.color.g, edges.color.b, 0)
            }
            GradientStop {
                position: 1
                color: Qt.rgba(edges.color.r, edges.color.g, edges.color.b, 1)
            }
        }
    }
}
