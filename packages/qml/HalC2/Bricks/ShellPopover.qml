import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell

// A floating panel over the window (pickers, previews, small forms): the
// popover surface, a quick fade in and no fade out, so a dismissed popover
// never lingers over what the user clicked next.
Popup {
    id: control

    padding: Theme.space.xs

    enter: Transition {
        NumberAnimation {
            property: "opacity"
            from: 0
            to: 1
            duration: 120
            easing.type: Easing.OutCubic
        }
    }

    exit: null

    background: ShellPopoverSurface {}
}
