import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HalC2.Shell

// A settings page's title, naming where the user is: "Settings / <section>",
// and what acts on the whole page (its children) at the right.
RowLayout {
    id: crumb

    property string section: ""
    default property alias actions: actionRow.data
    readonly property string text: qsTr("Settings / %1").arg(section)

    objectName: "settingsBreadcrumb"
    spacing: Theme.space.sm
    Accessible.role: Accessible.Heading
    Accessible.name: text

    Label {
        text: qsTr("Settings /")
        color: Theme.palette.color("inkTertiary", "#a1a1aa")
        font.pixelSize: Theme.type.title.size
        Accessible.ignored: true
    }

    Label {
        id: sectionLabel

        Layout.fillWidth: true
        text: crumb.section
        color: Theme.palette.color("ink", "#e4e4e7")
        font.pixelSize: Theme.type.title.size
        font.weight: Font.DemiBold
        elide: Text.ElideRight
        Accessible.ignored: true
    }

    // Centred on the title, and no taller than it: a page with buttons up
    // here starts its title where every other page does.
    Item {
        Layout.preferredWidth: actionRow.implicitWidth
        Layout.preferredHeight: sectionLabel.implicitHeight
        visible: actionRow.children.length > 0

        RowLayout {
            id: actionRow

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.space.sm
        }
    }
}
