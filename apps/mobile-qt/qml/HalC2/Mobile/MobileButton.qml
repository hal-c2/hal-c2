import QtQuick
import HalC2.Shell
import HalC2.Bricks

// The bricks' button at a finger's size: `primary` for a screen's or a
// dialog's main action, `subtle` for the ones beside it.
ShellButton {
    implicitHeight: 44
    leftPadding: 16
    rightPadding: 16
    font.pixelSize: Math.round(15 * Theme.fontScale)
}
