import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

MenuItem {
    id: control

    property bool destructive: false
    property string iconName: ""
    // A trailing check mark, for menus that show the current choice.
    property bool current: false
    // A project's icon (`projectIcons`), drawn in place of `iconName`.
    property var badge: null

    // Why the item is disabled, drawn as a muted second line under the label.
    // A disabled row gets no hover, so a tooltip could never show it.
    property string reason: ""

    implicitHeight: reason.length > 0 ? 28 + reasonText.contentHeight + 4 : 28
    leftPadding: 8
    rightPadding: 8
    font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
    font.pixelSize: Math.round(14 * Theme.fontScale)
    hoverEnabled: true

    contentItem: ColumnLayout {
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 28
            spacing: 8

            ProjectIcon {
                visible: control.badge !== null
                icon: control.badge
                size: 16
                Layout.alignment: Qt.AlignVCenter
            }

            ShellIcon {
                visible: control.iconName.length > 0 && control.badge === null
                name: control.iconName
                size: 16
                color: Qt.alpha(Theme.palette.color("textMuted", "#8b8b93"), 0.8)
                Layout.alignment: Qt.AlignVCenter
            }

            Text {
                text: control.text
                font: control.font
                color: control.destructive ? Theme.palette.color("error", "#ef4444") : Theme.palette.color("text", "#e4e4e7")
                opacity: control.enabled ? 1 : 0.5
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            ShellIcon {
                visible: control.current
                name: "check"
                size: 14
                color: Theme.palette.color("text", "#e4e4e7")
                Layout.alignment: Qt.AlignVCenter
            }
        }

        Text {
            id: reasonText

            objectName: "menuItemReason"
            visible: control.reason.length > 0
            Layout.fillWidth: true
            Layout.leftMargin: control.badge !== null || control.iconName.length > 0 ? 24 : 0
            Layout.bottomMargin: 4
            text: control.reason
            font.family: control.font.family
            font.pixelSize: Math.round(12 * Theme.fontScale)
            color: Theme.palette.color("textMuted", "#8b8b93")
            wrapMode: Text.Wrap
        }
    }

    background: Rectangle {
        radius: 6
        color: control.highlighted || control.hovered ? Theme.palette.color("accentSurface", "#27272a") : "transparent"
    }
}
