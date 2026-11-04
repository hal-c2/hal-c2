import QtQuick
import HalC2.Shell
import "js/panelTabs.js" as PanelTabs

// Where a tab's body shows, borrowed from a PanelBodies pool: the side panel
// has one, and so does each of the stage's panes. When another place shows a
// tab of the same single-body kind first, this one says so instead.
Item {
    id: slot

    required property PanelBodies bodies
    // The tab to show, or "" for none.
    property string tabId: ""
    readonly property bool hosting: bodies !== null && tabId.length > 0 && bodies.hosts[PanelTabs.bodyOf(tabId)] === slot

    onTabIdChanged: bodies?.rehost()
    Component.onCompleted: bodies?.enter(slot)
    Component.onDestruction: bodies?.leave(slot)
    onBodiesChanged: bodies?.enter(slot)

    Text {
        objectName: "panelBodyElsewhere"
        anchors.centerIn: parent
        width: Math.min(parent.width - 32, 320)
        visible: slot.tabId.length > 0 && !slot.hosting && slot.bodies !== null && PanelTabs.tabs[PanelTabs.kindOf(slot.tabId)] !== undefined
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        text: qsTr("%1 is showing in another pane.").arg(PanelTabs.tabs[PanelTabs.kindOf(slot.tabId)]?.label ?? "")
        color: Theme.palette.color("textMuted", "#8b8b93")
        font.pixelSize: Theme.type.meta.size
    }
}
