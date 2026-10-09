import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell

// A text input in the web app's clothes.
TextField {
    id: control

    implicitHeight: 30
    leftPadding: 10
    rightPadding: 10
    font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
    font.pixelSize: Math.round(13 * Theme.fontScale)
    color: Theme.palette.color("text", "#e4e4e7")
    placeholderTextColor: Theme.palette.color("placeholder", "#71717a")
    selectionColor: Theme.palette.color("accent", "#2563eb")
    selectedTextColor: Theme.palette.color("accentForeground", "#ffffff")
    opacity: enabled ? 1 : 0.64

    background: Rectangle {
        radius: Math.min(Theme.radius, control.height / 2)
        // `input` is a border colour in the web's palette: the field is
        // `bg-background`, or `input` at 32% in dark (input.tsx).
        color: Theme.appearance === "dark" ? Qt.alpha(Theme.palette.color("input", "#27272a"), 0.32) : Theme.palette.color("canvas", "#ffffff")
        border.color: control.activeFocus ? Theme.palette.color("focus", "#3b82f6") : Theme.palette.color("input", "#27272a")
        border.width: 1
    }
}
