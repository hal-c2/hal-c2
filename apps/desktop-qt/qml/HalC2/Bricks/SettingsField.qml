import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Templates as T
import HalC2.Shell

// A setting a page keeps itself (SettingsRow is for Settings' own keys): its
// title and description as SettingsRow draws them, and its controls: a small
// one (a switch) as `control`, to their right; wide ones below. A control it
// holds is named by the title and described by the description, unless it
// names itself or says what it is (a check box's text).
ColumnLayout {
    id: field

    property string title
    property string description
    default property alias content: below.data
    property alias control: beside.data
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("inkTertiary", "#a1a1aa")

    // Names the controls once they are made: their own `Accessible.name`
    // bindings are in place by then, and a Repeater's arrive later.
    function nameControls() {
        for (const item of Array.from(beside.children).concat(Array.from(below.children))) {
            const entry = item instanceof TextInput || item instanceof TextEdit;
            if (!(entry || item instanceof T.Control || item instanceof ShellChoice))
                continue;
            // A button's text is its name; a field's is what was typed.
            if (!entry && typeof item.text === "string" && item.text.length > 0)
                continue;
            if (item.Accessible.name.length === 0)
                item.Accessible.name = Qt.binding(() => field.title);
            if (item.Accessible.description.length === 0)
                item.Accessible.description = Qt.binding(() => field.description);
        }
    }

    Layout.fillWidth: true
    spacing: Theme.space.sm
    Component.onCompleted: nameControls()

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
            onChildrenChanged: Qt.callLater(field.nameControls)
        }
    }

    ColumnLayout {
        id: below

        Layout.fillWidth: true
        visible: children.length > 0
        spacing: Theme.space.sm
        onChildrenChanged: Qt.callLater(field.nameControls)
    }
}
