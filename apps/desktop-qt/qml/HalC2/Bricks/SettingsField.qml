import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// A setting a page keeps itself (SettingsRow is for Settings' own keys): its
// title and description as SettingsRow draws them, and its controls: a small
// one (a switch) as `control`, to their right; wide ones below.
ColumnLayout {
    id: field

    property string title
    property string description
    default property alias content: below.data
    property alias control: beside.data
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("inkTertiary", "#a1a1aa")

    Layout.fillWidth: true
    spacing: Theme.space.sm

    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.space.md

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.space.xxs

            Label {
                Layout.fillWidth: true
                visible: text.length > 0
                text: field.title
                color: field.foreground
                font.pixelSize: Theme.type.body.size
                font.weight: Font.Medium
                wrapMode: Text.Wrap
            }

            Label {
                Layout.fillWidth: true
                visible: text.length > 0
                text: field.description
                color: field.muted
                font.pixelSize: Theme.type.meta.size
                wrapMode: Text.Wrap
            }
        }

        RowLayout {
            id: beside

            Layout.alignment: Qt.AlignVCenter
            visible: children.length > 0
            spacing: Theme.space.sm
        }
    }

    ColumnLayout {
        id: below

        Layout.fillWidth: true
        visible: children.length > 0
        spacing: Theme.space.sm
    }
}
