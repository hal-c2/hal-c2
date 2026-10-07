import QtQuick
import "js/centreViews.js" as Views

// The centre for the route (js/centreViews.js): its thread or draft, home,
// pull requests or usage. Empty for a route kind no view draws.
Loader {
    id: host

    // The route kind to show; ShellWindow.route.kind by default layouts.
    property string kind: ""
    readonly property string brick: Views.brickFor(kind)
    // The loaded view's corner radius, for layouts that round the centre.
    property real radius: 0
    // Whether the loaded view is a conversation scrolled away from its latest output.
    readonly property bool conversationScrolled: status === Loader.Ready && (item as ThreadView)?.scrolledAway === true

    active: brick.length > 0
    source: active ? Qt.resolvedUrl(brick + ".qml") : ""
    onLoaded: item.radius = Qt.binding(() => host.radius)
}
