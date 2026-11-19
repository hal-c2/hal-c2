pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell

// One of a few values, side by side, as buttons; the chosen one is raised in
// the accent's ink. With `multiple`, `value` is a list and each click picks a
// value in or out. An option is {value, label, disabled}, or a string that is
// both. A disabled option is still read in the muted ink, never dimmed away.
// Each option is named `optionName` + its value, and says whether it is
// `chosen`. `picked` says which value was clicked; the owner sets `value`.
// `naturalWidth` is its width on one line, for a Flow or Row to size it by.
// It is a group named by its `Accessible.name` (a SettingsField gives it its
// title), and each option says in its description which group it is in, so
// two choices sharing labels ("Its default") are told apart by ear.
Flow {
    id: choice

    property var options: []
    property var value
    property bool multiple: false
    property string optionName: "choice:"
    readonly property color selectedFill: Theme.palette.color("surfaceRaised", "#1f1f24")
    readonly property color selectedInk: Theme.palette.color("accentText", "#60a5fa")
    readonly property real naturalWidth: {
        const shown = Array.from(choice.children).filter(child => child.chosen !== undefined && child.visible);
        return shown.reduce((sum, child) => sum + child.implicitWidth, 0) + Math.max(0, shown.length - 1) * choice.spacing;
    }

    signal picked(var value)

    spacing: Theme.space.sm
    Accessible.role: Accessible.Grouping

    Repeater {
        model: choice.options

        delegate: ShellButton {
            id: option

            required property var modelData
            readonly property var optionValue: typeof modelData === "object" ? modelData.value : modelData
            readonly property bool chosen: choice.multiple ? (choice.value ?? []).includes(optionValue) : optionValue === choice.value

            objectName: choice.optionName + optionValue
            text: typeof modelData === "object" ? modelData.label : modelData
            enabled: !(typeof modelData === "object" && modelData.disabled === true)
            opacity: 1
            checked: chosen
            hoverFill: chosen ? choice.selectedFill : Qt.alpha(accentSurface, accentSurface.a * 0.5)
            tint: chosen ? choice.selectedInk : enabled ? Theme.palette.color("text", "#e4e4e7") : Theme.palette.color("textMuted", "#a1a1aa")
            Accessible.role: choice.multiple ? Accessible.CheckBox : Accessible.RadioButton
            Accessible.checkable: true
            Accessible.checked: chosen
            Accessible.description: choice.Accessible.name
            Keys.onReturnPressed: choice.picked(optionValue)
            Keys.onEnterPressed: choice.picked(optionValue)
            onClicked: choice.picked(optionValue)
        }
    }
}
