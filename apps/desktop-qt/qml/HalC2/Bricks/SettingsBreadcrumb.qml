import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HalC2.Shell

// A settings page's title, naming where the user is: "Settings / <section>".
RowLayout {
    id: crumb

    property string section: ""
    readonly property string text: qsTr("Settings / %1").arg(section)

    objectName: "settingsBreadcrumb"
    spacing: 6
    Accessible.role: Accessible.Heading
    Accessible.name: text

    Label {
        text: qsTr("Settings /")
        color: Theme.palette.color("textMuted", "#a1a1aa")
        font.pixelSize: 18
        Accessible.ignored: true
    }

    Label {
        Layout.fillWidth: true
        text: crumb.section
        color: Theme.palette.color("text", "#e4e4e7")
        font.pixelSize: 18
        font.weight: Font.DemiBold
        elide: Text.ElideRight
        Accessible.ignored: true
    }
}
