import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell

// A screen's bar: the way back when there is one, its title, then its
// actions (the children).
ToolBar {
    id: bar

    property string title: ""
    property bool canGoBack: false
    default property alias actions: actions.data

    signal backRequested

    // Over the screen under it, whatever that draws past its own top edge.
    z: 1

    // The Theme's bar, with the hairline the desktop's header strip ends in.
    background: Rectangle {
        implicitHeight: 52
        color: Theme.palette.color("toolbar", "#0b0b0d")

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: Theme.palette.color("toolbarBorder", "#27272a")
        }
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 4
        anchors.rightMargin: 4
        spacing: 0

        MobileIconButton {
            objectName: "back"
            visible: bar.canGoBack
            iconName: "chevron-left"
            label: qsTr("Back")
            onClicked: bar.backRequested()
        }

        Label {
            objectName: "title"
            Layout.fillWidth: true
            Layout.leftMargin: bar.canGoBack ? 4 : 12
            text: bar.title
            elide: Text.ElideRight
            font.pixelSize: Math.round(17 * Theme.fontScale)
            font.weight: Font.DemiBold
            Accessible.role: Accessible.Heading
        }

        RowLayout {
            id: actions

            spacing: 0
        }
    }
}
