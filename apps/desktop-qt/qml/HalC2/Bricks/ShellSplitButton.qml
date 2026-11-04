import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The header's welded pill: an outline action with a chevron half that opens
// a menu. Attach the menu as a child and open it from `menuRequested`.
Item {
    id: split

    property string text: ""
    property string iconName: ""
    property bool actionEnabled: true
    property bool menuEnabled: true
    property string toolTip: ""
    // What the chevron half is called to assistive technology; the default names the action.
    property string menuName: text.length > 0 ? qsTr("More %1 options").arg(text) : qsTr("More options")
    property real maximumTextWidth: 200
    // Icon only, for narrow header strips.
    property bool compact: false

    signal clicked
    signal menuRequested

    implicitHeight: Theme.control.sm
    implicitWidth: row.implicitWidth
    opacity: enabled ? 1 : 0.64

    Rectangle {
        anchors.fill: parent
        radius: Theme.radiusMd
        color: Theme.palette.color("inputSurface", "#121317")
        border.color: Theme.palette.color("input", "#27272a")
        border.width: 1
    }

    RowLayout {
        id: row

        anchors.fill: parent
        spacing: 0

        ShellButton {
            id: action
            objectName: "splitAction"

            Layout.fillHeight: true
            Layout.maximumWidth: split.maximumTextWidth
            subtle: true
            // Nested inside the 1px border.
            radius: Math.max(0, Theme.radiusMd - 1)
            leftPadding: Theme.space.sm
            rightPadding: Theme.space.sm
            font.pixelSize: Theme.type.meta.size
            iconName: split.iconName
            enabled: split.actionEnabled
            text: split.compact ? "" : split.text
            Accessible.name: split.text
            toolTip: split.toolTip
            onClicked: split.clicked()
        }

        Rectangle {
            Layout.fillHeight: true
            Layout.topMargin: 1
            Layout.bottomMargin: 1
            implicitWidth: 1
            color: Theme.palette.color("input", "#27272a")
        }

        ShellButton {
            objectName: "menu"
            Layout.fillHeight: true
            Layout.preferredWidth: Theme.control.sm
            subtle: true
            radius: Math.max(0, Theme.radiusMd - 1)
            chevron: true
            chevronSize: Theme.icon.md
            enabled: split.menuEnabled
            // Two split buttons in one header must not both be "More options".
            Accessible.name: split.menuName
            onClicked: split.menuRequested()
        }
    }
}
