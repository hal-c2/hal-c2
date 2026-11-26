import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell

// A text input of several lines, drawn as ShellTextField: the input surface
// bordered by `input`, ringed while it holds the caret. It wraps by default.
TextArea {
    id: control

    padding: Theme.space.sm
    wrapMode: TextEdit.Wrap
    font.pixelSize: Theme.type.body.size
    color: Theme.palette.color("text", "#e4e4e7")
    placeholderTextColor: Theme.palette.color("placeholder", "#71717a")
    selectionColor: Theme.palette.color("accent", "#2563eb")
    selectedTextColor: Theme.palette.color("accentForeground", "#ffffff")
    opacity: enabled ? 1 : 0.64

    background: Rectangle {
        radius: Theme.radiusMd
        color: Theme.palette.color("inputSurface", "#121317")
        border.color: control.activeFocus ? Theme.palette.color("focus", "#3b82f6") : Theme.palette.color("input", "#27272a")
        border.width: 1
    }
}
