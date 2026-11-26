import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell

// A text input.
TextField {
    id: control

    implicitHeight: Theme.control.md
    leftPadding: Theme.space.sm
    rightPadding: Theme.space.sm
    font.pixelSize: Theme.type.body.size
    color: Theme.palette.color("text", "#e4e4e7")
    placeholderTextColor: Theme.palette.color("placeholder", "#71717a")
    selectionColor: Theme.palette.color("accent", "#2563eb")
    selectedTextColor: Theme.palette.color("accentForeground", "#ffffff")
    opacity: enabled ? 1 : 0.64

    background: Rectangle {
        radius: Theme.radiusMd
        color: Theme.palette.color("inputSurface", "#121317")
        // A field rings whenever it takes the caret, mouse included: like
        // :focus-visible on a text input, it shows where typing goes.
        border.color: control.activeFocus ? Theme.palette.color("focus", "#3b82f6") : Theme.palette.color("input", "#27272a")
        border.width: 1
    }
}
