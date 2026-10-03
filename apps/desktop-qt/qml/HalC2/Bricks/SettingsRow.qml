import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import "js/settingsRows.js" as Rows

// One row of a native settings page (js/settingsRows.js): its title and
// description, the control for its kind, and a reset while it is off its
// default. Values come from and go to Settings, which knows each key's store.
ColumnLayout {
    id: row

    required property var spec
    // Settings.setting is not a property: reading the stores it covers makes
    // the value follow them.
    readonly property var value: {
        Settings.device;
        Settings.document;
        return Settings.setting(spec.key);
    }
    readonly property bool atDefault: {
        Settings.device;
        Settings.document;
        return Settings.isDefault(spec.key);
    }
    // Rows the MC keeps wait for its document.
    readonly property bool ready: Settings.onDevice(spec.key) || Settings.ready
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    // Project grouping remembers the mode it was on for turning it back on.
    property string lastGrouping: ""

    objectName: "settingsRow:" + spec.key
    Layout.fillWidth: true
    spacing: 6

    function set(next) {
        Settings.set(spec.key, next);
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 12

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            RowLayout {
                spacing: 4

                Label {
                    text: row.spec.title
                    color: row.foreground
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                    font.weight: Font.Medium
                }

                ShellButton {
                    objectName: "reset"
                    visible: !row.atDefault
                    subtle: true
                    iconName: "undo-2"
                    iconSize: 12
                    implicitWidth: 20
                    implicitHeight: 20
                    Accessible.name: qsTr("Reset %1 to default").arg(row.spec.title.toLowerCase())
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Reset to default")
                    onClicked: Settings.reset(row.spec.key)
                }
            }

            Label {
                Layout.fillWidth: true
                text: Rows.describe(row.spec, row.value)
                visible: text.length > 0
                color: row.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }
        }

        Loader {
            Layout.alignment: Qt.AlignVCenter
            enabled: row.ready
            sourceComponent: {
                switch (row.spec.kind) {
                case "switch":
                    return switchControl;
                case "grouping":
                    return groupingControl;
                case "settleDays":
                    return settleControl;
                case "select":
                    return selectControl;
                case "number":
                    return numberControl;
                case "text":
                    return textControl;
                }
                return null;
            }
        }
    }

    // Inactive settling's days, shown while it is on.
    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: 12
        visible: row.spec.kind === "settleDays" && Rows.settleOn(row.value)
        spacing: 12

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Label {
                text: row.spec.daysTitle ?? ""
                color: row.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
            }

            Label {
                Layout.fillWidth: true
                text: row.spec.daysDescription ?? ""
                color: row.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }
        }

        SpinBox {
            objectName: "days"
            enabled: row.ready
            from: row.spec.min ?? 1
            to: row.spec.max ?? 90
            editable: true
            value: Rows.settleOn(row.value) ? row.value : (Settings.defaultOf(row.spec.key) ?? from)
            Accessible.name: row.spec.daysTitle ?? ""
            onValueModified: row.set(value)
        }
    }

    Component {
        id: switchControl

        Switch {
            objectName: "control"
            checked: row.value === true
            Accessible.name: row.spec.title
            onToggled: row.set(checked)
        }
    }

    Component {
        id: groupingControl

        Switch {
            objectName: "control"
            checked: Rows.groupingOn(row.value)
            Accessible.name: row.spec.title
            onToggled: {
                if (!checked) row.lastGrouping = row.value;
                row.set(Rows.groupingFromToggle(checked, row.lastGrouping));
            }
        }
    }

    Component {
        id: settleControl

        Switch {
            objectName: "control"
            checked: Rows.settleOn(row.value)
            Accessible.name: row.spec.title
            onToggled: row.set(Rows.settleFromToggle(checked, Settings.defaultOf(row.spec.key)))
        }
    }

    Component {
        id: selectControl

        ShellComboBox {
            objectName: "control"
            outline: true
            implicitWidth: 220
            model: row.spec.options
            textRole: "label"
            currentIndex: Rows.optionIndex(row.spec, row.value)
            Accessible.name: row.spec.title
            onActivated: index => row.set(row.spec.options[index].value)
        }
    }

    Component {
        id: numberControl

        SpinBox {
            objectName: "control"
            from: row.spec.min ?? 0
            to: row.spec.max ?? 100
            stepSize: row.spec.step ?? 1
            editable: true
            value: row.value ?? from
            textFromValue: (number, locale) => number + (row.spec.unit ?? "")
            valueFromText: (text, locale) => Rows.clamp(row.spec, parseInt(text), value)
            Accessible.name: row.spec.title
            onValueModified: row.set(value)
        }
    }

    Component {
        id: textControl

        ShellTextField {
            objectName: "control"
            implicitWidth: 220
            text: row.value ?? ""
            placeholderText: row.spec.placeholder ?? ""
            Accessible.name: row.spec.title
            // Saved when the user is done, not on every key.
            onEditingFinished: if (text !== (row.value ?? "")) row.set(text)
        }
    }
}
