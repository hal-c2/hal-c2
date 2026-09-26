import OpenTUI

// The frame: the thread list and the main column side by side, the status
// line below. Content goes into the main column.
//
// The thread list docks when `Shell.state.layout.sidebarVisible`; on a narrow
// terminal with the filter open (`sidebarAsMain`) it takes the whole width in
// place of the main column.
Window {
    id: win
    default property alias content: mainView.data
    property alias body: bodyRow
    property alias sidebar: sidebarView
    property alias main: mainView
    property alias statusLine: statusView

    readonly property var layout: Shell.state.layout

    color: Theme.colors.bg
    flexDirection: "column"

    Item {
        id: bodyRow
        objectName: "body"
        flexDirection: "row"
        flexGrow: 1

        Sidebar {
            id: sidebarView
            objectName: "sidebar"
            visible: win.layout.sidebarVisible || win.layout.sidebarAsMain
            width: win.layout.sidebarAsMain ? Shell.state.size.columns : win.layout.listWidth
            filterFocused: Shell.state.mode === "filter"
        }
        Item {
            id: mainView
            objectName: "main"
            visible: !win.layout.sidebarAsMain
            flexGrow: 1
            flexDirection: "column"
        }
    }

    StatusLine { id: statusView; objectName: "statusLine" }
}
