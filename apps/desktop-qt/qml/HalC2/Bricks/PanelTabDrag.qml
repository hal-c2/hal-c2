import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell

// Drags a right-panel tab between the side panel and the stage: put in the
// tab, it leaves clicks to the tab and, once the pointer moves, carries a
// chip of the tab over the window to a DropArea taking `PanelTabDrag.key`
// (the stage's panes, the side panel), which reads the tab from
// `bodies.dragging`.
Item {
    id: dragger

    required property PanelBodies bodies
    required property string tabId
    property string title: ""
    property string iconName: ""

    readonly property string key: "hal-c2/panel-tab"
    readonly property bool dragging: handler.active

    DragHandler {
        id: handler

        // On the tab itself: a drag handler on an item laid over a button
        // takes the button's presses, so it never clicks.
        parent: dragger.parent
        target: null
        onActiveChanged: {
            if (active) {
                dragger.bodies.dragging = dragger.tabId;
            } else {
                chip.Drag.drop();
                dragger.bodies.dragging = "";
            }
        }
    }

    Rectangle {
        id: chip

        readonly property point at: handler.centroid.scenePosition

        parent: Overlay.overlay
        visible: handler.active
        x: at.x - width / 2
        y: at.y - height / 2
        z: 100
        width: chipRow.implicitWidth + 20
        height: 28
        radius: Theme.radiusSm
        color: Theme.palette.color("surfaceRaised", "#1f1f24")
        border.color: Theme.palette.color("accent", "#2563eb")
        opacity: 0.95
        Drag.active: handler.active
        Drag.keys: [dragger.key]
        Drag.hotSpot.x: width / 2
        Drag.hotSpot.y: height / 2

        Row {
            id: chipRow

            anchors.centerIn: parent
            spacing: Theme.space.sm

            ShellIcon {
                visible: dragger.iconName.length > 0
                name: dragger.iconName
                size: 13
                color: Theme.palette.color("text", "#e4e4e7")
                anchors.verticalCenter: parent.verticalCenter
            }

            Text {
                text: dragger.title
                color: Theme.palette.color("text", "#e4e4e7")
                font.pixelSize: Theme.type.meta.size
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
}
