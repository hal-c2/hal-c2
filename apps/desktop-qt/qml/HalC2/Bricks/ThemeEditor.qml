import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Edits one of this device's themes over the window. The draft is the
// controller's (Themes.editing), so unsaved changes outlive the page that
// opened it. A canvas and an accent grow the whole palette (Themes.derive);
// the advanced view edits every role, grouped by family (Themes.families)
// and filtered by name. Saving adds or replaces the theme and applies it.
Popup {
    id: editor

    readonly property var draft: Themes.editing
    // The colours being edited, by role.
    readonly property var colors: draft.colors ?? ({})
    property string filter: ""
    property bool advanced: false
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    // The advanced view's rows: a heading per family, then its roles.
    readonly property var rows: {
        const list = [];
        for (const family of Themes.families) {
            const roles = family.roles.filter(role => role.toLowerCase().includes(editor.filter));
            if (roles.length === 0) continue;
            list.push({ heading: family.title, role: "" });
            for (const role of roles) list.push({ heading: "", role: role });
        }
        return list;
    }

    function change(fields) {
        Themes.setEditing(Object.assign({}, draft, fields));
    }

    function setColor(role, value) {
        const next = Object.assign({}, colors);
        next[role] = value.trim();
        // The two a theme is made from grow the rest again.
        const grown = role === "canvas" || role === "accent" ? Themes.derive(next.canvas ?? "", next.accent ?? "") : ({});
        change({ colors: Object.keys(grown).length > 0 && !advanced ? grown : next });
    }

    function save() {
        const saved = Themes.saveCustom({
            id: draft.id,
            label: draft.label,
            appearance: draft.appearance,
            colors: colors
        });
        if (saved.length > 0) close();
    }

    objectName: "themeEditor"
    anchors.centerIn: parent
    scale: Shell.state.layout?.zoom ?? 1
    transformOrigin: Item.TopLeft
    width: Math.min(560, parent ? parent.width / scale - 48 : 560)
    height: Math.min(640, parent ? parent.height / scale - 48 : 640)
    // Not modal, so the window stays usable under it and its toggle still closes it.
    modal: false
    closePolicy: Popup.CloseOnEscape
    padding: 16
    onClosed: Themes.editorOpen = false
    Component.onCompleted: if (Themes.editorOpen) open()

    Connections {
        target: Themes

        function onEditorOpenChanged() {
            if (Themes.editorOpen) {
                editor.open();
            } else {
                editor.close();
            }
        }
    }

    background: Rectangle {
        radius: Theme.radius
        color: Theme.palette.color("popover", "#18181b")
        border.color: Theme.palette.color("border", "#27272a")
    }

    component ColorField: RowLayout {
        id: colorField

        required property string role
        property string label: role

        spacing: 8

        Rectangle {
            implicitWidth: 18
            implicitHeight: 18
            radius: 4
            color: editor.colors[colorField.role] ?? "transparent"
            border.color: Theme.palette.color("border", "#27272a")
        }

        Label {
            Layout.fillWidth: true
            text: colorField.label
            color: editor.foreground
            font.pixelSize: 12
            elide: Text.ElideRight
        }

        ShellTextField {
            objectName: "color:" + colorField.role
            implicitWidth: 140
            text: editor.colors[colorField.role] ?? ""
            Accessible.name: colorField.label
            onEditingFinished: editor.setColor(colorField.role, text)
        }
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
                objectName: "name"
                Layout.fillWidth: true
                placeholderText: qsTr("Theme name")
                text: editor.draft.label ?? ""
                Accessible.name: qsTr("Theme name")
                onTextEdited: editor.change({ label: text })
            }

            ShellComboBox {
                outline: true
                model: [qsTr("Light"), qsTr("Dark")]
                currentIndex: editor.draft.appearance === "dark" ? 1 : 0
                Accessible.name: qsTr("Appearance")
                onActivated: index => editor.change({ appearance: index === 1 ? "dark" : "light" })
            }
        }

        ColorField {
            Layout.fillWidth: true
            role: "canvas"
            label: qsTr("Background")
            visible: !editor.advanced
        }

        ColorField {
            Layout.fillWidth: true
            role: "accent"
            label: qsTr("Accent")
            visible: !editor.advanced
        }

        ShellButton {
            objectName: "advanced"
            subtle: true
            text: editor.advanced ? qsTr("Hide advanced colors") : qsTr("Show advanced colors")
            onClicked: editor.advanced = !editor.advanced
        }

        ShellTextField {
            objectName: "filter"
            Layout.fillWidth: true
            visible: editor.advanced
            placeholderText: qsTr("Filter colors")
            Accessible.name: qsTr("Filter colors")
            onTextEdited: editor.filter = text.trim().toLowerCase()
        }

        ListView {
            objectName: "roles"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: editor.advanced
            clip: true
            spacing: 4
            model: editor.advanced ? editor.rows : []
            ScrollBar.vertical: ScrollBar {}

            delegate: Item {
                id: roleRow

                required property var modelData

                width: ListView.view.width
                height: modelData.role === "" ? 26 : 28

                Label {
                    anchors.bottom: parent.bottom
                    visible: roleRow.modelData.role === ""
                    text: roleRow.modelData.heading
                    color: editor.muted
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                }

                Loader {
                    anchors.fill: parent
                    active: roleRow.modelData.role !== ""
                    sourceComponent: ColorField {
                        role: roleRow.modelData.role
                    }
                }
            }
        }

        Item {
            Layout.fillHeight: true
            visible: !editor.advanced
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
                enabled: (editor.draft.label ?? "").trim().length > 0
                onClicked: editor.save()
            }
        }
    }
}
