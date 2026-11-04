import QtQuick
import HalC2.Shell

// The dimmed backdrop behind a modal popup: `Overlay.modal: ShellScrim {}`.
Rectangle {
    // The window's shortcuts stand down while one shows (ShellWindow.popupHoldsKeys).
    objectName: "shellScrim"
    color: Theme.palette.color("scrim", "#8f000000")
}
