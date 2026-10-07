import QtQuick
import QtQuick.Controls.Material
import HalC2.Shell
import HalC2.Bricks

// A bar button that is one of the bricks' lucide icons, a finger wide.
ToolButton {
    id: button

    property string iconName: ""
    // What the button does, for a screen reader.
    required property string label

    implicitWidth: 48
    implicitHeight: 48
    Accessible.name: label

    contentItem: Item {
        ShellIcon {
            anchors.centerIn: parent
            name: button.iconName
            size: 22
            color: Theme.palette.color(button.enabled ? "text" : "textMuted", "#e4e4e7")
        }
    }
}
