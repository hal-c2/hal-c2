import QtQuick
import HalC2.Shell
import "js/centreViews.js" as Views

// The native centre for the route (js/centreViews.js), where the page would
// be. Empty while the route is still the page's: layouts show the WebSurface
// instead, by ShellWindow.nativeCentreOpen.
Loader {
    id: host

    // The route kind to show; ShellWindow.route.kind by default layouts.
    property string kind: ""
    readonly property string brick: Views.brickFor(kind)
    // The loaded view's corner radius, for layouts that round the centre.
    property real radius: 0

    active: brick.length > 0
    source: active ? Qt.resolvedUrl(brick + ".qml") : ""
    onLoaded: item.radius = Qt.binding(() => host.radius)
}
