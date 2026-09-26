import OpenTUI

// The frame: the thread list, the main column and the detail panel side by
// side, the status line below. Content goes into the main column's centred
// content area; the terminal drawer sits under it.
//
// The thread list docks when `Shell.state.layout.sidebarVisible`; on a narrow
// terminal with the filter open (`sidebarAsMain`) it takes the whole width in
// place of the main column.
//
// Extension points (the host opens and sizes them, a shell fills them):
//   rightPanelComponent: Component { … }   // `layout.rightPanel` (kind, width, asMain)
//   drawerComponent: Component { … }       // `layout.drawer` (open, rows)
Window {
    id: win
    default property alias content: contentView.data
    property alias body: bodyRow
    property alias sidebar: sidebarView
    property alias main: mainView
    property alias statusLine: statusView
    property alias rightPanelComponent: rightPanelLoader.sourceComponent
    property alias drawerComponent: drawerLoader.sourceComponent

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
            visible: !win.layout.sidebarAsMain && !win.layout.rightPanel.asMain
            flexGrow: 1
            flexShrink: 1
            flexDirection: "column"

            // Capped at 96 cells and centred, like the web's chat column.
            Item {
                id: contentView
                objectName: "content"
                width: win.layout.contentWidth
                alignSelf: "center"
                flexGrow: 1
                flexShrink: 1
                flexDirection: "column"
            }
            Item {
                id: drawerView
                objectName: "drawer"
                visible: win.layout.drawer.open
                height: win.layout.drawer.rows
                flexShrink: 0
                flexDirection: "column"
                Loader { id: drawerLoader }
            }
        }
        Item {
            id: rightPanelView
            objectName: "rightPanel"
            visible: win.layout.rightPanel.visible && !win.layout.sidebarAsMain
            width: win.layout.rightPanel.asMain ? win.layout.mainWidth : win.layout.rightPanel.width
            flexShrink: 0
            flexDirection: "column"
            Loader { id: rightPanelLoader; active: win.layout.rightPanel.visible }
        }
    }

    StatusLine { id: statusView; objectName: "statusLine" }

    // Snooze wakes and other time boundaries: the host says when the list is next due.
    Timer {
        interval: Math.max(1, Shell.state.clock.refreshInMs)
        running: Shell.state.clock.refreshInMs > 0
        onTriggered: {
            Shell.dispatch("clock.tick")
            restart()
        }
    }

    ContextMenu {}
}
