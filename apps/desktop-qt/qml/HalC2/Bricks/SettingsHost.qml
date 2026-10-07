import QtQuick
import "js/settingsPages.js" as Pages

// The settings page for the section showing (js/settingsPages.js).
Loader {
    id: host

    // The section to show; ShellWindow.settingsSection by default layouts.
    property string section: ""
    readonly property string brick: Pages.brickFor(section)
    // The loaded page's corner radius, for layouts that round the centre.
    property real radius: 0

    active: brick.length > 0
    source: active ? Qt.resolvedUrl(brick + ".qml") : ""
    onLoaded: item.radius = Qt.binding(() => host.radius)
}
