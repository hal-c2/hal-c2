import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// What a list, panel or view shows when it has nothing to show, failed, or
// is still loading: an icon in an inset tile, a title, one short sentence and
// at most two actions. Loading, empty and error use the same geometry, so
// nothing jumps when one becomes another.
ColumnLayout {
    id: root

    property string iconName: "circle-dashed"
    property string title: ""
    // One sentence; it wraps to two lines at most.
    property string description: ""
    // The main action, drawn as the accent button; empty for none.
    property string actionText: ""
    // A second, quieter action; empty for none.
    property string secondaryActionText: ""

    signal actionTriggered
    signal secondaryActionTriggered

    spacing: Theme.space.sm
    width: Math.min(implicitWidth, 360)

    Rectangle {
        objectName: "emptyStateIcon"
        Layout.alignment: Qt.AlignHCenter
        Layout.bottomMargin: Theme.space.xs
        implicitWidth: 40
        implicitHeight: 40
        radius: Theme.radiusMd
        color: Theme.palette.color("inset", "#0a0b0d")
        border.color: Theme.palette.color("border", "#262a31")
        border.width: 1

        ShellIcon {
            anchors.centerIn: parent
            name: root.iconName
            size: Theme.icon.xl
            color: Theme.palette.color("textMuted", "#8b919e")
        }
    }

    Text {
        objectName: "emptyStateTitle"
        visible: text.length > 0
        Layout.alignment: Qt.AlignHCenter
        Layout.maximumWidth: 360
        text: root.title
        color: Theme.palette.color("text", "#f2f3f5")
        font.pixelSize: Theme.type.title.size
        font.weight: Theme.type.title.weight
        lineHeight: Theme.type.title.lineHeight
        lineHeightMode: Text.FixedHeight
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
    }

    Text {
        objectName: "emptyStateDescription"
        visible: text.length > 0
        Layout.alignment: Qt.AlignHCenter
        Layout.maximumWidth: 360
        Layout.fillWidth: true
        text: root.description
        color: Theme.palette.color("inkSecondary", "#b8bdc7")
        font.pixelSize: Theme.type.body.size
        lineHeight: Theme.type.body.lineHeight
        lineHeightMode: Text.FixedHeight
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
    }

    RowLayout {
        visible: root.actionText.length > 0 || root.secondaryActionText.length > 0
        Layout.alignment: Qt.AlignHCenter
        Layout.topMargin: Theme.space.xs
        spacing: Theme.space.sm

        ShellButton {
            objectName: "emptyStateSecondaryAction"
            visible: root.secondaryActionText.length > 0
            text: root.secondaryActionText
            onClicked: root.secondaryActionTriggered()
        }

        ShellButton {
            objectName: "emptyStateAction"
            visible: root.actionText.length > 0
            primary: true
            text: root.actionText
            onClicked: root.actionTriggered()
        }
    }
}
