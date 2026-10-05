import QtQuick as Q
import HalC2.Shell

// The `Text` a plugin file gets from `import OpenTUI` (PluginRegistry): the
// shell's text colour and font unless the plugin says otherwise, so it reads
// on any theme.
Q.Text {
    color: Theme.palette.color("text", "#e4e4e7")
    font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Qt.application.font.family
    font.pixelSize: Math.round(12 * Theme.fontScale)
}
