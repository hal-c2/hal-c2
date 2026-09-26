import OpenTUI

// The frame, as the OpenTUI client draws it: the thread list at full height,
// then the main column. The main column holds the conversation (content goes
// into its centred content area) with the detail panel beside it, as tall as
// the conversation pane; the terminal drawer under both; and the key-hint and
// status row at the bottom.
//
// The thread list docks when `Shell.state.layout.sidebarVisible`; on a narrow
// terminal with the filter open (`sidebarAsMain`) it takes the whole width in
// place of the main column. A detail panel too wide to share (`asMain`) takes
// the conversation pane's place above the prompt.
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
    flexDirection: "row"

    Sidebar {
        id: sidebarView
        objectName: "sidebar"
        visible: win.layout.sidebarVisible || win.layout.sidebarAsMain
        width: win.layout.sidebarAsMain ? Shell.state.size.columns : win.layout.listWidth
        filterFocused: Shell.state.mode === "filter"
        listFocused: Shell.state.mode === "list"
    }
    Item {
        id: mainColumn
        objectName: "mainColumn"
        visible: !win.layout.sidebarAsMain
        flexGrow: 1
        flexShrink: 1
        flexDirection: "column"

        Item {
            id: bodyRow
            objectName: "body"
            flexDirection: "row"
            flexGrow: 1
            flexShrink: 1

            Item {
                id: mainView
                objectName: "main"
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
            }
            Item {
                id: rightPanelView
                objectName: "rightPanel"
                visible: win.layout.rightPanel.visible
                position: win.layout.rightPanel.asMain ? "absolute" : "relative"
                left: 0
                top: 0
                z: win.layout.rightPanel.asMain ? 10 : 0
                width: win.layout.rightPanel.asMain ? win.layout.mainWidth : win.layout.rightPanel.width
                height: win.layout.panesRows
                flexShrink: 0
                flexDirection: "column"
                Loader { id: rightPanelLoader; active: win.layout.rightPanel.visible }
            }
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
        StatusLine { id: statusView; objectName: "statusLine" }
    }

    // Snooze wakes and other time boundaries: the host says when the list is next due.
    Timer {
        interval: Math.max(1, Shell.state.clock.refreshInMs)
        running: Shell.state.clock.refreshInMs > 0
        onTriggered: {
            Shell.dispatch("clock.tick")
            restart()
        }
    }

    ImageViewer {}
    ContextMenu {}
}
