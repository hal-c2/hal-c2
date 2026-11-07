import QtQuick

// The route's centre (RouteView) and a thread's stage beside or over it
// (ThreadArea), for a layout that places its own Composer under it. The stage
// borrows the tab bodies of the window's side panel (ShellWindow.panelBodies).
//
//   CentreHost { kind: root.route?.kind ?? "" }
ThreadArea {
    // The route kind to show; ShellWindow.route.kind by default layouts.
    property string kind: ""
    // The route's view (RouteView.item), and the brick it is drawn by.
    readonly property Item item: centreView.item as Item
    readonly property string brick: centreView.brick

    routeKind: kind
    composerShown: false
    bodies: (Window.window as ShellWindow)?.panelBodies ?? null
}
