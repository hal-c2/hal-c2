import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import "js/settingsRows.js" as Rows

// Settings → Appearance, natively: the appearance mode and theme this device
// draws with (Themes), and the interface, font and motion rows.
SettingsPage {
    id: page

    objectName: "appearanceSettings"
    title: qsTr("Appearance")
    rows: Rows.appearance

    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
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

        Layout.fillWidth: true
        spacing: 6

        Label {
            id: label

            Layout.topMargin: 12
            color: page.foreground
            font.pixelSize: 14
            font.weight: Font.DemiBold
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: page.line
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
        text: qsTr("Themes")
    }

    Repeater {
        model: Themes.available

        delegate: RowLayout {
            id: themeRow

            required property var modelData
            readonly property bool active: Themes.resolvedId === modelData.id

            objectName: "theme:" + modelData.id
            Layout.fillWidth: true
            spacing: 6

            ShellButton {
                Layout.fillWidth: true
                subtle: !themeRow.active
                text: themeRow.modelData.label
                iconName: themeRow.active ? "check" : ""
                Accessible.name: qsTr("Use %1").arg(themeRow.modelData.label)
                onClicked: Themes.choose(themeRow.modelData.id)
            }

            Label {
                text: themeRow.modelData.source === "environment" ? qsTr("From this environment") : themeRow.modelData.appearances.length === 1 ? (themeRow.modelData.appearances[0] === "dark" ? qsTr("Dark only") : qsTr("Light only")) : ""
                visible: text.length > 0
                color: page.muted
                font.pixelSize: 12
            }
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
                font.pixelSize: 13
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
}
