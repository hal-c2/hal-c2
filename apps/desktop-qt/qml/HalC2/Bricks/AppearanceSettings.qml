pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Dialogs
import QtQuick.Layouts
import HalC2.Shell
import "js/settingsRows.js" as Rows

// Settings → Appearance, natively: the appearance mode and theme this device
// draws with (Themes), its own themes (created, edited, duplicated and
// removed here), and the interface, font and motion rows.
SettingsPage {
    id: page

    objectName: "appearanceSettings"
    title: qsTr("Appearance")
    rows: Rows.appearance

    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    // The collection variants picked to remove together.
    property var selected: []
    readonly property var modes: [
        { mode: "system", label: qsTr("System") },
        { mode: "light", label: qsTr("Light") },
        { mode: "dark", label: qsTr("Dark") }
    ]

    // Options for one appearance's half: the whole theme's choice, then every
    // theme that has that appearance.
    function halfOptions(appearance) {
        const options = [{ id: "", label: qsTr("Same as theme") }];
        for (const theme of Themes.available) {
            if (theme.appearances.indexOf(appearance) >= 0) options.push({ id: theme.id, label: theme.label });
        }
        return options;
    }

    function halfIndex(options, appearance) {
        const id = Themes.halves[appearance] ?? "";
        return Math.max(0, options.findIndex(option => option.id === id));
    }

    component Heading: ColumnLayout {
        property alias text: label.text
        // What acts on the whole section, at the heading's right.
        default property alias actions: actions.data

        Layout.fillWidth: true
        spacing: 6

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 12
            spacing: 8

            Label {
                id: label

                Layout.fillWidth: true
                color: Theme.palette.color("text", "#e4e4e7")
                font.pixelSize: Math.round(14 * Theme.fontScale)
                font.weight: Font.DemiBold
            }

            RowLayout {
                id: actions

                spacing: 8
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: Theme.palette.color("border", "#27272a")
        }
    }

    // A theme to draw with: its colors, its name, and a mark on the one in use (`checked`).
    component ThemeChoice: AbstractButton {
        id: choice

        // The theme's canvas, accent and text.
        property var swatch: []
        readonly property color accentSurface: Theme.palette.color("accentSurface", "#27272a")

        Layout.fillWidth: true
        implicitHeight: 32
        leftPadding: 8
        rightPadding: 8
        hoverEnabled: true
        font.pixelSize: Math.round(13 * Theme.fontScale)
        font.weight: Font.Medium

        background: Rectangle {
            radius: Math.min(Theme.radius, 8)
            color: choice.checked || choice.hovered || choice.down ? choice.accentSurface : Qt.alpha(choice.accentSurface, 0)
            border.width: choice.checked || choice.visualFocus ? 1 : 0
            border.color: choice.visualFocus ? Theme.palette.color("focus", "#3b82f6") : Theme.palette.color("accent", "#2563eb")
        }

        contentItem: RowLayout {
            spacing: 8

            Row {
                spacing: 3

                Repeater {
                    model: choice.swatch

                    delegate: Rectangle {
                        required property string modelData

                        objectName: "swatch"
                        width: 14
                        height: 14
                        radius: 7
                        color: modelData
                        border.color: Theme.palette.color("border", "#27272a")
                    }
                }
            }

            Label {
                Layout.fillWidth: true
                text: choice.text
                font: choice.font
                color: page.foreground
                elide: Text.ElideRight
            }

            ShellIcon {
                visible: choice.checked
                name: "check"
                size: 14
                color: page.foreground
            }
        }
    }

    // The shell's theme file (Theme.path) is drawn over whatever is chosen
    // below, so the page says so: the choices are still saved, and show again
    // once the file is gone.
    Rectangle {
        id: shellTheme

        readonly property string name: Theme.name.length > 0 ? Theme.name : qsTr("theme.json")

        objectName: "shellTheme"
        Layout.fillWidth: true
        visible: Theme.loaded || Theme.lastError.length > 0
        implicitHeight: shellThemeText.implicitHeight + 20
        radius: Math.min(Theme.radius, 8)
        color: Theme.palette.color("surfaceRaised", "#18181b")
        border.color: Theme.palette.color("info", "#3b82f6")

        ColumnLayout {
            id: shellThemeText

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: 12
            spacing: 4

            Label {
                objectName: "shellThemeTitle"
                Layout.fillWidth: true
                visible: Theme.loaded
                text: qsTr("The shell theme file “%1” is in use").arg(shellTheme.name)
                color: page.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.DemiBold
                wrapMode: Text.Wrap
            }

            Label {
                objectName: "shellThemeEffect"
                Layout.fillWidth: true
                visible: Theme.loaded
                text: (Theme.followsSystemAppearance ? qsTr("Its colors are drawn over the theme chosen below, and it follows the color scheme chosen here.") : qsTr("Its colors are drawn over the theme chosen below, and it keeps the app %1 whatever the color scheme.").arg(Theme.appearance === "dark" ? qsTr("dark") : qsTr("light"))) + " " + qsTr("Your choices are still saved, and show in full once the file is removed.")
                color: page.foreground
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            Label {
                objectName: "shellThemeError"
                Layout.fillWidth: true
                visible: text.length > 0
                text: Theme.lastError
                color: Theme.palette.color("error", "#f87171")
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            Label {
                objectName: "shellThemePath"
                Layout.fillWidth: true
                text: Theme.path
                color: page.muted
                font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
                font.pixelSize: Math.round(11 * Theme.fontScale)
                wrapMode: Text.WrapAnywhere
            }
        }
    }

    Heading {
        text: qsTr("Color scheme")
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 8

        Repeater {
            model: page.modes

            delegate: ShellButton {
                required property var modelData

                objectName: "mode:" + modelData.mode
                Layout.fillWidth: true
                text: modelData.label
                primary: Themes.mode === modelData.mode
                Accessible.name: qsTr("%1 appearance").arg(modelData.label)
                onClicked: Themes.setMode(modelData.mode)
            }
        }
    }

    Heading {
        objectName: "themes"
        text: qsTr("Themes")

        ShellButton {
            objectName: "newTheme"
            iconName: "plus"
            text: qsTr("New theme")
            onClicked: {
                // A new theme starts from the active one, saved as a theme of its own.
                const draft = Themes.draft("");
                draft.id = "";
                draft.label = qsTr("%1 copy").arg(draft.label);
                Themes.edit(draft);
            }
        }

        ShellButton {
            objectName: "importTheme"
            text: qsTr("Import theme")
            onClicked: {
                Themes.clearImport();
                importer.open();
            }
        }
    }

    // The standard look: no theme chosen, and the way back from one.
    ThemeChoice {
        objectName: "theme:hal-c2"
        text: qsTr("HAL-C2")
        swatch: Themes.standardSwatch
        checked: Themes.resolvedId === "hal-c2"
        Accessible.name: qsTr("Use %1").arg(text)
        onClicked: Themes.choose("")
    }

    Repeater {
        model: Themes.available

        delegate: RowLayout {
            id: themeRow

            required property var modelData
            readonly property bool custom: modelData.source === "custom"
            readonly property bool active: Themes.resolvedId === modelData.id

            objectName: "theme:" + modelData.id
            Layout.fillWidth: true
            spacing: 6

            // A collection's variants are picked to remove several at once.
            ShellCheckBox {
                objectName: "select:" + themeRow.modelData.id
                visible: themeRow.custom && themeRow.modelData.collection.length > 0
                checked: page.selected.indexOf(themeRow.modelData.id) >= 0
                Accessible.name: qsTr("Select %1").arg(themeRow.modelData.label)
                onToggled: page.selected = checked ? page.selected.concat([themeRow.modelData.id]) : page.selected.filter(id => id !== themeRow.modelData.id)
            }

            ThemeChoice {
                objectName: "use:" + themeRow.modelData.id
                text: themeRow.modelData.label
                swatch: themeRow.modelData.swatch ?? []
                checked: themeRow.active
                Accessible.name: qsTr("Use %1").arg(themeRow.modelData.label)
                onClicked: Themes.choose(themeRow.modelData.id)
            }

            Label {
                text: themeRow.modelData.source === "environment" ? qsTr("From this environment") : themeRow.modelData.appearances.length === 1 ? (themeRow.modelData.appearances[0] === "dark" ? qsTr("Dark only") : qsTr("Light only")) : ""
                visible: text.length > 0
                color: page.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }

            Label {
                text: themeRow.modelData.collection ?? ""
                visible: text.length > 0
                color: page.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }

            ShellButton {
                subtle: true
                iconName: "copy"
                Accessible.name: qsTr("Duplicate %1").arg(themeRow.modelData.label)
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Duplicate")
                onClicked: Themes.duplicate(themeRow.modelData.id)
            }

            ShellButton {
                visible: themeRow.custom
                subtle: true
                iconName: "pencil-ruler"
                Accessible.name: qsTr("Edit %1").arg(themeRow.modelData.label)
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Edit")
                onClicked: Themes.edit(Themes.draft(themeRow.modelData.id))
            }

            ShellButton {
                objectName: "export:" + themeRow.modelData.id
                subtle: true
                iconName: "download"
                Accessible.name: qsTr("Export %1").arg(themeRow.modelData.label)
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Export")
                onClicked: {
                    exporter.themeId = themeRow.modelData.id;
                    exporter.currentFile = exporter.currentFolder + "/" + themeRow.modelData.id + ".json";
                    exporter.open();
                }
            }

            ShellButton {
                visible: themeRow.custom
                subtle: true
                iconName: "x"
                Accessible.name: qsTr("Remove %1").arg(themeRow.modelData.label)
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Remove")
                onClicked: Themes.requestRemove(themeRow.modelData.id)
            }
        }
    }

    ShellButton {
        objectName: "removeSelected"
        visible: page.selected.length > 0
        tint: Theme.palette.color("error", "#ef4444")
        text: qsTr("Remove selected (%1)").arg(page.selected.length)
        onClicked: {
            Themes.requestRemoveMany(page.selected);
            page.selected = [];
        }
    }

    Heading {
        text: qsTr("Light and dark")
    }

    Repeater {
        model: [
            { appearance: "light", label: qsTr("Light theme") },
            { appearance: "dark", label: qsTr("Dark theme") }
        ]

        delegate: RowLayout {
            id: halfRow

            required property var modelData
            readonly property var options: {
                Themes.available;
                return page.halfOptions(modelData.appearance);
            }

            Layout.fillWidth: true
            spacing: 12

            Label {
                Layout.fillWidth: true
                text: halfRow.modelData.label
                color: page.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
            }

            ShellComboBox {
                objectName: "half:" + halfRow.modelData.appearance
                outline: true
                implicitWidth: 220
                model: halfRow.options
                textRole: "label"
                currentIndex: {
                    Themes.halves;
                    return page.halfIndex(halfRow.options, halfRow.modelData.appearance);
                }
                Accessible.name: halfRow.modelData.label
                onActivated: index => Themes.chooseHalf(halfRow.modelData.appearance, halfRow.options[index].id)
            }
        }
    }

    ThemeImportDialog {
        id: importer

        parent: Overlay.overlay
    }

    FileDialog {
        id: exporter

        property string themeId: ""

        title: qsTr("Export theme")
        fileMode: FileDialog.SaveFile
        nameFilters: [qsTr("Theme files (*.json)")]
        defaultSuffix: "json"
        onAccepted: Themes.exportTheme(themeId, selectedFile.toString().replace(/^file:\/\//, ""))
    }
}
