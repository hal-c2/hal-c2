import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Edits one of this device's themes: its name, appearance and every colour
// role (Themes.roles). `edit(draft)` opens it on a Themes.draft; saving adds
// or replaces the theme and applies it.
Popup {
    id: editor

    property var draft: ({})
    // The colours being edited, by role.
    property var colors: ({})
    property string filter: ""
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")

    function edit(next) {
        draft = next;
        colors = Object.assign({}, next.colors);
        name.text = next.label;
        filter = "";
        open();
    }

    function save() {
        const saved = Themes.saveCustom({
            id: draft.id,
            label: name.text,
            appearance: appearance.currentIndex === 1 ? "dark" : "light",
            colors: colors
        });
        if (saved.length > 0) close();
    }

    objectName: "themeEditor"
    anchors.centerIn: parent
    width: Math.min(560, parent ? parent.width - 48 : 560)
    height: Math.min(640, parent ? parent.height - 48 : 640)
    modal: true
    padding: 16

    background: Rectangle {
        radius: Theme.radius
        color: Theme.palette.color("popover", "#18181b")
        border.color: Theme.palette.color("border", "#27272a")
    }

    contentItem: ColumnLayout {
        spacing: 10

        Label {
            text: editor.draft.id ? qsTr("Edit theme") : qsTr("New theme")
            color: editor.foreground
            font.pixelSize: 16
            font.weight: Font.DemiBold
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            ShellTextField {
                id: name

                objectName: "name"
                Layout.fillWidth: true
                placeholderText: qsTr("Theme name")
                Accessible.name: qsTr("Theme name")
            }

            ShellComboBox {
                id: appearance

                outline: true
                model: [qsTr("Light"), qsTr("Dark")]
                currentIndex: editor.draft.appearance === "dark" ? 1 : 0
                Accessible.name: qsTr("Appearance")
            }
        }

        ShellTextField {
            Layout.fillWidth: true
            placeholderText: qsTr("Filter colors")
            text: editor.filter
            onTextEdited: editor.filter = text.trim().toLowerCase()
        }

        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 4
            model: Themes.roles.filter(role => role.toLowerCase().includes(editor.filter))
            ScrollBar.vertical: ScrollBar {}

            delegate: RowLayout {
                id: roleRow

                required property string modelData

                width: ListView.view.width
                spacing: 8

                Rectangle {
                    implicitWidth: 18
                    implicitHeight: 18
                    radius: 4
                    color: editor.colors[roleRow.modelData] ?? "transparent"
                    border.color: Theme.palette.color("border", "#27272a")
                }

                Label {
                    Layout.fillWidth: true
                    text: roleRow.modelData
                    color: editor.foreground
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }

                ShellTextField {
                    objectName: "color:" + roleRow.modelData
                    implicitWidth: 140
                    text: editor.colors[roleRow.modelData] ?? ""
                    Accessible.name: roleRow.modelData
                    onEditingFinished: {
                        const next = Object.assign({}, editor.colors);
                        next[roleRow.modelData] = text.trim();
                        editor.colors = next;
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Item {
                Layout.fillWidth: true
            }

            ShellButton {
                subtle: true
                text: qsTr("Cancel")
                onClicked: editor.close()
            }

            ShellButton {
                objectName: "save"
                primary: true
                text: qsTr("Save")
                enabled: name.text.trim().length > 0
                onClicked: editor.save()
            }
        }
    }
}
