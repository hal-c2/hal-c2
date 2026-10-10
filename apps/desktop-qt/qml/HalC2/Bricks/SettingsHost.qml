import QtQuick
import HalC2.Shell
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
    // Escape that nothing in the page took leaves Settings, as the web's route does
    // (a popup, dialog or search clear takes it first).
    Keys.onEscapePressed: event => {
        Shell.dispatch("settings.back");
        event.accepted = true;
    }
    onLoaded: item.radius = Qt.binding(() => host.radius)
}
