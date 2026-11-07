import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// A project of the Sidebar brick's legacy tree (`sidebar.tree`): its chevron,
// mark and name, its threads listed under it. A click folds or unfolds it,
// a right click (or a long press) asks for its menu, and while projects are
// sorted by hand (`draggable`) a drag puts it elsewhere.
Item {
    id: header

    required property var project
    property var projectIcon: null
    property bool focused: false
    property bool touch: false

    signal toggled
    signal menuRequested(real windowX, real windowY)
    // Where the pointer is in the window while a drag lasts, and whether it
    // ended in a drop.
    signal dragMoved(real windowY)
    signal dragEnded(bool dropped)

    implicitHeight: Theme.control.lg
    Accessible.role: Accessible.Button
    Accessible.name: project.displayName ?? ""
    Accessible.onPressAction: header.toggled()

    readonly property color ink: hover.hovered ? Theme.palette.color("ink", "#e4e4e7") : Theme.palette.color("inkSecondary", "#b8bdc7")

    Rectangle {
        anchors.fill: parent
        radius: Theme.radiusMd
        color: hover.hovered ? Theme.palette.color("sidebarRowHover", "#1c1c21") : "transparent"
        border.width: header.focused ? 1 : 0
        border.color: Theme.palette.color("focus", "#3b82f6")
    }

    HoverHandler {
        id: hover
    }

    TapHandler {
        acceptedButtons: Qt.LeftButton
        onTapped: header.toggled()
    }

    TapHandler {
        acceptedButtons: Qt.RightButton
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        gesturePolicy: TapHandler.WithinBounds
        onPressedChanged: {
            if (pressed) {
                header.menuRequested(point.scenePosition.x, point.scenePosition.y);
            }
        }
    }

    TapHandler {
        enabled: header.touch
        acceptedDevices: PointerDevice.TouchScreen
        onLongPressed: header.menuRequested(point.scenePosition.x, point.scenePosition.y)
    }

    DragHandler {
        property bool cancelled: false

        target: null
        enabled: header.project.draggable === true
        acceptedDevices: header.touch ? PointerDevice.Mouse | PointerDevice.TouchPad : PointerDevice.AllDevices
        acceptedButtons: Qt.LeftButton
        onActiveChanged: {
            if (active) {
                cancelled = false;
            } else {
                header.dragEnded(!cancelled);
            }
        }
        onCanceled: cancelled = true
        onCentroidChanged: {
            if (active) {
                header.dragMoved(centroid.scenePosition.y);
            }
        }
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.space.xs
        anchors.rightMargin: Theme.space.sm
        spacing: Theme.space.xs

        ShellChevron {
            direction: "down"
            size: Theme.icon.sm
            color: header.ink
            rotation: header.project.expanded ? 0 : -90
            Layout.alignment: Qt.AlignVCenter
        }

        ProjectIcon {
            Layout.alignment: Qt.AlignVCenter
            size: Theme.icon.sm + Theme.space.xxs
            icon: header.projectIcon
            name: header.project.displayName ?? ""
        }

        Text {
            objectName: "projectName"
            Layout.fillWidth: true
            text: header.project.displayName ?? ""
            elide: Text.ElideRight
            color: header.ink
            font.pixelSize: Theme.type.body.size
            font.weight: Font.Medium
        }
    }
}
