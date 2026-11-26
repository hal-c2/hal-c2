import QtQuick
import HalC2.Shell

// The one chevron: menus, pickers, disclosures and pagers all draw this. It
// points `direction` ("down", "up", "left" or "right"), and takes the icon
// scale's stroke for its size like any other icon.
ShellIcon {
    property string direction: "down"

    name: "chevron-" + direction
    size: Theme.icon.sm
    color: Theme.palette.color("textMuted", "#8b919e")
}
