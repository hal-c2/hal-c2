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
    // A muted second part after the text (what tells two same-named entries
    // apart); it is elided before the text is.
    property string detail: ""
    // Why the item is disabled, drawn as a muted second line under the label.
    // A disabled row gets no hover, so a tooltip could never show it.
    property string reason: ""
    // The keys that run it, as the user reads them ("Ctrl+N"), in the right
    // column where a submenu's chevron would be.
    property string shortcut: ""

    readonly property bool hasIcon: badge !== null || iconName.length > 0

    readonly property bool menuHasIcons: menu !== null && menu.hasIcons === true

    implicitHeight: reason.length > 0 ? Theme.control.md + reasonText.contentHeight + Theme.space.xs : Theme.control.md
    leftPadding: Theme.space.sm
    rightPadding: Theme.space.sm
    font.pixelSize: Theme.type.body.size
    font.weight: Theme.type.body.weight
    hoverEnabled: true
    Accessible.description: [detail, reason].filter(part => part.length > 0).join(". ")

    contentItem: ColumnLayout {
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.control.md
            spacing: Theme.space.sm

            ProjectIcon {
                visible: control.badge !== null
                icon: control.badge
                size: Theme.icon.md
                Layout.alignment: Qt.AlignVCenter
            }

            ShellIcon {
                visible: control.iconName.length > 0 && control.badge === null
                name: control.iconName
                size: Theme.icon.md
                color: control.destructive ? Theme.palette.color("destructive", "#f87171") : Theme.palette.color("inkSecondary", "#b8bdc7")
                Layout.alignment: Qt.AlignVCenter
            }

            // The icon column, kept when other rows of the menu have icons.
            Item {
                visible: !control.hasIcon && control.menuHasIcons
                Layout.preferredWidth: Theme.icon.md
                Layout.preferredHeight: Theme.icon.md
            }

            Text {
                objectName: "menuItemLabel"
                text: control.text
                font: control.font
                color: control.destructive ? Theme.palette.color("destructive", "#f87171") : Theme.palette.color("text", "#f2f3f5")
                opacity: control.enabled ? 1 : 0.5
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                Layout.fillWidth: control.detail.length === 0
                Layout.minimumWidth: control.detail.length === 0 ? 0 : Math.min(implicitWidth, 80)
            }

            Text {
                objectName: "menuItemDetail"
                visible: control.detail.length > 0
                text: control.detail
                font: control.font
                color: Theme.palette.color("textMuted", "#8b919e")
                opacity: control.enabled ? 1 : 0.5
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            // The right column: the shortcut, a submenu's chevron, or a
            // picker's check on the current choice.
            Text {
                objectName: "menuItemShortcut"
                visible: control.shortcut.length > 0 && control.subMenu === null
                text: control.shortcut
                font.family: control.font.family
                font.pixelSize: Theme.type.meta.size
                font.features: {
                    "tnum": 1
                }
                color: Theme.palette.color("textMuted", "#8b919e")
                opacity: control.enabled ? 1 : 0.5
                verticalAlignment: Text.AlignVCenter
                Layout.leftMargin: Theme.space.sm
                Layout.alignment: Qt.AlignVCenter
            }

            ShellChevron {
                objectName: "menuItemChevron"
                visible: control.subMenu !== null
                direction: "right"
                size: Theme.icon.sm
                color: Theme.palette.color("textMuted", "#8b919e")
                Layout.alignment: Qt.AlignVCenter
            }

            ShellIcon {
                objectName: "menuItemCheck"
                visible: control.current
                name: "check"
                size: Theme.icon.md
                color: Theme.palette.color("accentText", "#5b8cff")
                Layout.alignment: Qt.AlignVCenter
            }
        }

        Text {
            id: reasonText

            objectName: "menuItemReason"
            visible: control.reason.length > 0
            Layout.fillWidth: true
            Layout.leftMargin: control.hasIcon || control.menuHasIcons ? Theme.icon.md + Theme.space.sm : 0
            Layout.bottomMargin: Theme.space.xs
            text: control.reason
            font.family: control.font.family
            font.pixelSize: Theme.type.meta.size
            color: Theme.palette.color("textMuted", "#8b919e")
            wrapMode: Text.Wrap
        }
    }

    // The highlight nests inside the menu's corner, 4px in.
    background: Rectangle {
        objectName: "menuItemHighlight"
        radius: Math.max(0, Theme.radiusLg - Theme.space.xs)
        color: control.highlighted || control.hovered || control.visualFocus ? Theme.palette.color("accentSurface", "#f2f3f514") : "transparent"
    }
}
