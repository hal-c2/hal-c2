import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell

// A number field in the theme's colours: a bordered input
// with a minus stepper on the left and a plus on the right. Replaces the stock
// SpinBox, whose colours come from a system palette.
//
// `valueTyped` reports a number as soon as what is typed reads one in range, before
// Return or the keyboard leaving makes it the value: a page saved with a button
// handles it as well as `valueModified`, so a count typed and then saved is kept.
SpinBox {
    id: control

    signal valueTyped(int typed)

    readonly property color border: Theme.palette.color("input", "#27272a")
    readonly property color accentSurface: Theme.palette.color("accentSurface", "#27272a")

    implicitHeight: Theme.control.md
    implicitWidth: 120
    padding: 0
    font.pixelSize: Theme.type.body.size
    hoverEnabled: true
    opacity: enabled ? 1 : 0.64
    // Digits only, never grouped: a value reported while it is typed is shown again
    // in the field, and "2,000" would take no fifth digit.
    textFromValue: (value, locale) => String(Math.round(value))
    // What reads no number (an emptied field, a lone minus) keeps the value it
    // held, where the stock box would fall to `from`.
    valueFromText: (text, locale) => {
        const typed = text.trim().length > 0 ? Number(text) : NaN;
        return Number.isFinite(typed) ? Math.round(typed) : control.value;
    }

    contentItem: TextInput {
        z: 2
        text: control.displayText
        clip: width < implicitWidth
        font: control.font
        color: Theme.palette.color("text", "#e4e4e7")
        selectionColor: Theme.palette.color("accent", "#2563eb")
        selectedTextColor: Theme.palette.color("accentForeground", "#ffffff")
        horizontalAlignment: Qt.AlignHCenter
        verticalAlignment: Qt.AlignVCenter
        readOnly: !control.editable
        validator: control.validator
        inputMethodHints: control.inputMethodHints
        onTextEdited: {
            if (acceptableInput)
                control.valueTyped(control.valueFromText(text, control.locale));
        }
    }

    up.indicator: Rectangle {
        objectName: "up"

        x: control.mirrored ? 0 : control.width - width
        y: 1
        width: 28
        height: control.height - 2
        radius: Math.max(0, control.background.radius - 1)
        color: control.up.pressed || control.up.hovered ? control.accentSurface : "transparent"
        opacity: control.value < control.to ? 1 : 0.4

        ShellIcon {
            anchors.centerIn: parent
            name: "plus"
            size: 14
            color: Theme.palette.color("text", "#e4e4e7")
        }
    }

    down.indicator: Rectangle {
        objectName: "down"

        x: control.mirrored ? control.width - width : 0
        y: 1
        width: 28
        height: control.height - 2
        radius: Math.max(0, control.background.radius - 1)
        color: control.down.pressed || control.down.hovered ? control.accentSurface : "transparent"
        opacity: control.value > control.from ? 1 : 0.4

        ShellIcon {
            anchors.centerIn: parent
            name: "minus"
            size: 14
            color: Theme.palette.color("text", "#e4e4e7")
        }
    }

    background: Rectangle {
        radius: Theme.radiusMd
        color: Theme.palette.color("inputSurface", "#121317")
        border.color: control.activeFocus ? Theme.palette.color("focus", "#3b82f6") : control.border
        border.width: 1
    }
}
