pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// A Space or a page in a list, a finger wide: a tap opens it, and the button at
// its end or a long press offers what can be done with it.
ItemDelegate {
    id: row

    property string title: ""
    property string iconName: "file-text"
    property int depth: 0
    // The name of the button that offers its actions; none when it has none.
    property string menuName: ""

    signal menuRequested

    implicitHeight: 52
    leftPadding: 16 + depth * 16
    rightPadding: 4
    topPadding: 0
    bottomPadding: 0
    Accessible.name: title
    onPressAndHold: {
        if (menuName !== "")
            menuRequested();
    }

    contentItem: RowLayout {
        spacing: 12

        ShellIcon {
            name: row.iconName
            size: 18
            color: Theme.palette.color("textMuted", "#a1a1aa")
        }

        Label {
            Layout.fillWidth: true
            text: row.title
            elide: Text.ElideRight
            font.pixelSize: Math.round(15 * Theme.fontScale)
        }

        MobileIconButton {
            objectName: row.menuName
            visible: row.menuName !== ""
            iconName: "ellipsis"
            label: qsTr("Actions for %1").arg(row.title)
            onClicked: row.menuRequested()
        }
    }
}
