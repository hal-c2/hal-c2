import QtQuick
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The built-in layout of the bricks in a ShellWindow: sidebar, header strip,
// timeline, composer, right panel, settings and terminal drawer. DefaultShell
// fills its window with it, and so does any other root that wants the
// desktop's layout beside a layout of its own (apps/mobile-qt).
//
//   ShellWindow { id: root; DefaultLayout { anchors.fill: parent; window: root } }
Item {
    id: layout

    // The window it lays out: its route, settings section and thread list.
    required property ShellWindow window
    // Whether the layout frames the window: its tabs, sidebar band and header
    // are then the drag handle of a frameless window and carry its buttons. A
    // root whose system frames the window (Android) turns it off.
    property bool framesWindow: true
    // Whether the layout shows the window's ConnectionNotice, as a strip at the
    // foot of the window that takes its own room, so it covers neither the
    // header's controls nor the thread. It does once the window's own notice
    // is turned off (`ShellWindow.connectionNotice`), so the two never both
    // show; a root that places the notice itself (the phone) turns this off too.
    property bool connectionNotice: !window.connectionNotice
    // A page an MC plugin added is showing: it takes the place of everything
    // right of the sidebar.
    readonly property bool pluginTab: (window.route?.tab ?? "threads") !== "threads" && !window.settingsActive
    // A frameless window's buttons (WindowControls), drawn once in the
    // window's corner so they stay there whatever is open; macOS draws its own.
    readonly property bool windowButtons: framesWindow && Theme.frameless && Qt.platform.os !== "osx"
    // What the corner lies over, which keeps `windowButtonsInset` of its
    // right end clear: the tabs, the right panel's tab strip, the thread
    // details' header, or the thread's header.
    readonly property string corner: tabsView.visible ? "tabs" : panelView.visible && panelView.open && !panelSheet ? "panel" : detailsView.visible && !detailsSheet ? "details" : "centre"
    readonly property real windowButtonsInset: windowButtons ? windowButtonsView.width + 2 * windowButtonsView.anchors.rightMargin : 0

    // The window has no room for the thread list beside the thread
    // (LayoutController): shown, the list lies over the thread instead.
    readonly property bool sidebarOverlay: Shell.state.layout?.sidebarOverlay === true
    // How the columns give way as the window narrows, the thread keeping
    // `threadMinimumWidth` beside whatever is docked: first the right panel
    // goes over the thread as a sheet (at 980, or sooner when what else is
    // open leaves it no room), then the thread details do, then the thread
    // list (above).
    readonly property int threadMinimumWidth: 360
    readonly property real besideList: width - (navigation.visible && !sidebarOverlay ? navigation.width : 0) - (folderExplorer.visible ? folderExplorer.width : 0)
    readonly property bool detailsSheet: besideList - detailsView.implicitWidth < threadMinimumWidth
    readonly property real besidePanel: besideList - (detailsView.visible && !detailsSheet ? detailsView.implicitWidth : 0) - threadMinimumWidth
    readonly property bool panelNarrow: width <= 980 || besidePanel < panelView.minimumWidth
    readonly property bool panelSheet: panelNarrow
    // The sheet: 42% of the window up to 448, 88% up to 384 under 760.
    readonly property real panelSheetWidth: width < 760 ? Math.min(0.88 * width, 384) : Math.max(320, Math.min(0.42 * width, 448))
    // A sheet starts under the header, whose toggle puts it away again.
    readonly property real headerHeight: workspaceView.visible ? workspaceView.height : chromeBand.visible ? chromeBand.height : 0
    // Where the window is, less what changes while it stays there (the title).
    readonly property string place: [window.route?.kind, window.route?.threadKey, window.route?.draftId, window.route?.section].join("|")

    // Going somewhere from a list over the thread puts the list away, and so
    // does an Escape nothing inside wanted.
    onPlaceChanged: if (sidebarOverlay && !window.sidebarCollapsed)
        Shell.dispatch("sidebar.toggle")
    Keys.onEscapePressed: event => {
        if (sidebarOverlay && navigation.visible)
            Shell.dispatch("sidebar.toggle");
        else if (panelScrim.visible)
            Shell.dispatch("rightPanel.toggle");
        else
            event.accepted = false;
    }

    // Local QML extensions can customize one brick without copying the layout.
    property alias sidebar: sidebarView
    property alias composer: composerView
    property alias workspace: workspaceView
    property alias centreView: centreHost
    property alias rightPanel: panelView
    property alias stage: stageView
    property alias toolbar: toolbarLoader.sourceComponent
    property alias navigationPanel: sidebarExtension.sourceComponent
    // Null in a build without a terminal (Terminals.supported).
    readonly property Item terminalDrawer: terminalView.item as Item

    // The right panel's tab bodies, shared by the panel and the stage.
    PanelBodies {
        id: panelBodies
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ShellTabs {
            id: tabsView
            objectName: "shellTabs"
            Layout.fillWidth: true
            visible: pages.length > 0 && !layout.window.settingsActive
            window: layout.framesWindow ? layout.window : null
            windowControls: false
            trailingInset: layout.windowButtonsInset
        }

        RowLayout {
            id: body

            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            GridLayout {
                id: navigation
                Layout.fillHeight: true
                Layout.fillWidth: false
                Layout.preferredWidth: columns === 2 ? sidebarView.shownWidth + sidebarExtension.implicitWidth : sidebarExtension.active ? Math.max(300, sidebarView.shownWidth) : sidebarView.shownWidth
                Layout.maximumWidth: Layout.preferredWidth
                Layout.minimumWidth: 0
                // Over the thread, it takes no room from it.
                Layout.rightMargin: layout.sidebarOverlay ? -Layout.preferredWidth : 0
                z: layout.sidebarOverlay ? 2 : 0
                columns: sidebarExtension.active && layout.window.width >= 1100 ? 2 : 1
                rowSpacing: 0
                columnSpacing: 0
                visible: !layout.window.settingsActive && !layout.window.sidebarCollapsed

                Sidebar {
                    id: sidebarView
                    objectName: "threadSidebar"
                    // The width while its edge is dragged, else the layout's.
                    property int dragWidth: -1
                    readonly property int shownWidth: dragWidth >= 0 ? dragWidth : layout.window.sidebarWidth

                    Layout.fillHeight: true
                    Layout.fillWidth: true
                    Layout.preferredWidth: shownWidth
                    Layout.minimumWidth: 0
                    showBrand: true
                    window: layout.framesWindow ? layout.window : null

                    // The right edge: drag to resize, double click for the default width.
                    MouseArea {
                        objectName: "sidebarEdge"

                        property real pressX: 0
                        property int pressWidth: 0

                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: 6
                        cursorShape: Qt.SplitHCursor
                        preventStealing: true
                        onPressed: mouse => {
                            pressX = mapToItem(navigation.parent, mouse.x, 0).x;
                            pressWidth = sidebarView.shownWidth;
                        }
                        onPositionChanged: mouse => {
                            if (pressed)
                                sidebarView.dragWidth = Math.max(208, Math.round(pressWidth + mapToItem(navigation.parent, mouse.x, 0).x - pressX));
                        }
                        onReleased: {
                            const width = sidebarView.dragWidth;
                            sidebarView.dragWidth = -1;
                            if (width >= 0 && width !== layout.window.sidebarWidth)
                                Shell.dispatch("sidebar.resize", { width: width });
                        }
                        onCanceled: sidebarView.dragWidth = -1
                        onDoubleClicked: Shell.dispatch("sidebar.resize", {})
                    }
                }

                Loader {
                    id: sidebarExtension
                    Layout.fillHeight: true
                    Layout.fillWidth: true
                    Layout.preferredWidth: status === Loader.Ready ? (item as Item)?.implicitWidth ?? 0 : 0
                    active: sourceComponent !== null
                    visible: active
                }
            }

            // The folder explorer (folders.toggle), beside the thread list.
            Loader {
                id: folderExplorer
                objectName: "folderExplorerHost"
                Layout.fillHeight: true
                Layout.preferredWidth: active ? 340 : 0
                active: (Shell.state.folders?.open ?? false) && !layout.window.settingsActive && !layout.pluginTab
                visible: active
                sourceComponent: FolderExplorer {}
            }

            SettingsNav {
                objectName: "settingsNav"
                Layout.fillHeight: true
                Layout.preferredWidth: 256
                visible: layout.window.settingsActive
            }

            ColumnLayout {
                id: centre

                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: !layout.pluginTab
                spacing: 0

                // Away from a thread (home, pull requests, usage, settings)
                // there is no header: a band in its place, for a frameless
                // window to be dragged by and for its buttons to lie over.
                Rectangle {
                    id: chromeBand
                    objectName: "chromeBand"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 36
                    visible: layout.framesWindow && Theme.frameless && !workspaceView.visible && !tabsView.visible
                    color: Theme.palette.color("canvas", "#0f0f12")

                    DragHandler {
                        target: null
                        grabPermissions: PointerHandler.CanTakeOverFromAnything
                        onActiveChanged: if (active)
                            layout.window.startSystemMove()
                    }

                    TapHandler {
                        onDoubleTapped: layout.window.visibility === Window.Maximized ? layout.window.showNormal() : layout.window.showMaximized()
                    }
                }

                Workspace {
                    id: workspaceView
                    objectName: "workspace"

                    Layout.fillWidth: true
                    visible: ready
                    sidebarToggle: layout.window.sidebarCollapsed
                    panelToggle: panelView.available ? panelView.open : null
                    detailsToggle: Shell.state.panel ? Shell.state.panel.detailsOpen === true : null
                    window: layout.framesWindow ? layout.window : null
                    windowControls: false
                    trailingInset: layout.corner === "centre" ? layout.windowButtonsInset : 0
                }

                Loader {
                    id: toolbarLoader
                    objectName: "extensionToolbar"

                    Layout.fillWidth: true
                    Layout.preferredHeight: status === Loader.Ready ? (item as Item)?.implicitHeight ?? 0 : 0
                    active: sourceComponent !== null
                    visible: active
                }

                // The settings section showing.
                SettingsHost {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    section: layout.window.settingsSection
                    visible: layout.window.settingsActive
                }

                // The route's centre, and a thread's stage: the conversation
                // (timeline and composer) with the stage beside it, or, with
                // the timeline put away, the stage over the composer and a
                // line of what the agent did last. Where the two do not fit
                // side by side, one shows at a time and that line switches.
                Item {
                    id: threadArea

                    readonly property var stageModel: Shell.state.panel?.stage ?? null
                    readonly property bool staged: (layout.window.route?.kind ?? "") === "thread" && (stageModel?.tabs ?? []).length > 0
                    readonly property bool focusMode: staged && stageModel.focus === true
                    readonly property bool narrow: width < layout.threadMinimumWidth + stageView.minimumWidth + 1
                    readonly property bool timelineShown: !staged || !focusMode
                    readonly property bool besideShown: staged && !focusMode && !narrow
                    // The conversation's width beside the stage: the one being
                    // dragged to, the controller's, or 40%.
                    property int dragWidth: -1
                    readonly property int chatWidth: {
                        const kept = dragWidth >= 0 ? dragWidth : (stageModel?.chatWidth ?? 0);
                        const wanted = kept > 0 ? kept : Math.round(width * 0.4);
                        return Math.max(layout.threadMinimumWidth, Math.min(wanted, width - stageView.minimumWidth - 1));
                    }

                    objectName: "threadArea"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: !layout.window.settingsActive

                    ColumnLayout {
                        id: conversation

                        width: threadArea.besideShown ? threadArea.chatWidth : threadArea.width
                        height: threadArea.height
                        spacing: 0

                        // The route's centre: a thread, draft, home, pull requests or usage.
                        CentreHost {
                            id: centreHost
                            objectName: "centreHost"

                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            kind: layout.window.route?.kind ?? ""
                            visible: threadArea.timelineShown
                        }

                        // Where the stage lies while the timeline is put away.
                        Item {
                            id: stageRoom

                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: !threadArea.timelineShown
                        }

                        // What the agent did last while the timeline is put
                        // away, or the stage's tabs while it is out of room;
                        // a click shows the other.
                        Rectangle {
                            objectName: "stageActivity"
                            Layout.fillWidth: true
                            Layout.preferredHeight: 30
                            visible: threadArea.staged && (threadArea.focusMode || threadArea.narrow)
                            color: activityTap.hovered ? Theme.palette.color("surface", "#141416") : Theme.palette.color("chrome", "#0b0b0d")
                            Accessible.role: Accessible.Button
                            Accessible.name: activityAction.text
                            Accessible.onPressAction: Shell.dispatch("stage.toggleFocus")

                            Rectangle {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                height: 1
                                color: Theme.palette.color("border", "#27272a")
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                spacing: 8

                                // Still while the agent works: a dot, not a spinner.
                                Rectangle {
                                    Layout.preferredWidth: 6
                                    Layout.preferredHeight: 6
                                    radius: 3
                                    visible: threadArea.focusMode
                                    color: Threads.timeline?.working === true ? Theme.palette.color("accent", "#2563eb") : Theme.palette.color("textMuted", "#8b8b93")
                                }

                                Text {
                                    objectName: "stageActivityText"
                                    Layout.fillWidth: true
                                    textFormat: Text.PlainText
                                    elide: Text.ElideRight
                                    text: {
                                        if (!threadArea.focusMode)
                                            return qsTr("%n tab(s) in the centre", "", threadArea.stageModel?.tabs.length ?? 0);
                                        const latest = String(Threads.timeline?.latest ?? "");
                                        return latest.length > 0 ? latest : qsTr("Nothing in this thread yet");
                                    }
                                    color: Theme.palette.color("text", "#e4e4e7")
                                    font.pixelSize: Math.round(12 * Theme.fontScale)
                                }

                                Text {
                                    id: activityAction
                                    text: threadArea.focusMode ? qsTr("Show the timeline") : qsTr("Show the tabs")
                                    color: Theme.palette.color("textMuted", "#8b8b93")
                                    font.pixelSize: Math.round(12 * Theme.fontScale)
                                }
                            }

                            HoverHandler {
                                id: activityTap
                                cursorShape: Qt.PointingHandCursor
                            }

                            TapHandler {
                                onTapped: Shell.dispatch("stage.toggleFocus")
                            }
                        }

                        Composer {
                            id: composerView

                            Layout.fillWidth: true
                            visible: ready
                            conversationScrolled: centreHost.conversationScrolled
                        }
                    }

                    // Between the conversation and the stage: drag to resize,
                    // double click for the default width.
                    Rectangle {
                        objectName: "stageSplitter"
                        x: threadArea.chatWidth
                        width: 1
                        height: threadArea.height
                        visible: threadArea.besideShown
                        color: Theme.palette.color("border", "#27272a")

                        MouseArea {
                            property real pressX: 0
                            property int pressWidth: 0

                            anchors.centerIn: parent
                            width: 7
                            height: parent.height
                            cursorShape: Qt.SplitHCursor
                            preventStealing: true
                            onPressed: mouse => {
                                pressX = mapToItem(threadArea, mouse.x, 0).x;
                                pressWidth = threadArea.chatWidth;
                            }
                            onPositionChanged: mouse => {
                                if (pressed)
                                    threadArea.dragWidth = Math.round(pressWidth + mapToItem(threadArea, mouse.x, 0).x - pressX);
                            }
                            onReleased: {
                                const width = threadArea.chatWidth;
                                threadArea.dragWidth = -1;
                                if (width !== (threadArea.stageModel?.chatWidth ?? 0))
                                    Shell.dispatch("stage.resize", {
                                        width: width
                                    });
                            }
                            onCanceled: threadArea.dragWidth = -1
                            onDoubleClicked: Shell.dispatch("stage.resize", {})
                        }
                    }

                    Stage {
                        id: stageView

                        readonly property int minimumWidth: 360

                        bodies: panelBodies
                        visible: threadArea.staged && (threadArea.focusMode || threadArea.besideShown)
                        x: threadArea.focusMode ? 0 : threadArea.chatWidth + 1
                        width: threadArea.focusMode ? threadArea.width : threadArea.width - x
                        height: threadArea.focusMode ? stageRoom.height : threadArea.height
                    }
                }

                // The terminal drawer, in a build that has a terminal: the
                // brick draws with the Ghostty module, which is then there.
                Loader {
                    id: terminalView

                    Layout.fillWidth: true
                    active: Terminals.supported
                    source: active ? "TerminalDrawer.qml" : ""
                }
            }

            PluginPages {
                objectName: "pluginPages"
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: layout.pluginTab
            }

            // The thread details column (threadPanel.toggle), beside the thread.
            ThreadDetailsPanel {
                id: detailsView
                Layout.fillHeight: true
                trailingInset: layout.corner === "details" ? layout.windowButtonsInset : 0
                Layout.preferredWidth: implicitWidth
                // Over the thread, it takes no room from it.
                Layout.leftMargin: layout.detailsSheet ? -implicitWidth : 0
                Layout.topMargin: layout.detailsSheet ? layout.headerHeight : 0
                z: layout.detailsSheet ? 2 : 0
                details: Shell.state.panel?.details ?? null
                visible: details !== null && !layout.pluginTab
            }

            RightPanel {
                id: panelView
                objectName: "rightPanel"

                Layout.fillHeight: true
                // A sheet takes no room from the thread either.
                Layout.leftMargin: layout.panelSheet ? -implicitWidth : 0
                Layout.topMargin: layout.panelSheet ? layout.headerHeight : 0
                z: layout.panelSheet ? 2 : 0
                ownToggle: false
                bodies: panelBodies
                resizable: !layout.panelSheet
                trailingInset: layout.corner === "panel" ? layout.windowButtonsInset : 0
                Layout.preferredWidth: implicitWidth
                // The thread keeps room of its own.
                maximumWidth: layout.panelSheet ? layout.panelSheetWidth : layout.besidePanel
                visible: available && !layout.pluginTab
            }
        }

        // The window's connection, while it is not live: the one place that says so.
        Item {
            id: noticeStrip

            objectName: "connectionNoticeStrip"
            Layout.fillWidth: true
            Layout.preferredHeight: visible ? windowNotice.height + 16 : 0
            visible: layout.connectionNotice && (windowNotice.troubled || windowNotice.warning !== null)

            ConnectionNotice {
                id: windowNotice

                y: 8
            }
        }

        // The status bar: empty, and so absent, until a plugin fills it.
        PluginSlot {
            objectName: "statusbarSlot"
            name: "statusbar"
            visible: shown.length > 0
            Layout.fillWidth: true
            Layout.leftMargin: 12
            Layout.topMargin: 4
            Layout.bottomMargin: 4
        }
    }

    // Beside a thread list shown over the thread: a click there puts the list
    // away.
    Rectangle {
        id: sidebarScrim
        objectName: "sidebarScrim"
        visible: layout.sidebarOverlay && navigation.visible
        x: navigation.width
        y: navigation.parent.y
        width: parent.width - x
        height: navigation.height
        color: Theme.palette.color("scrim", "#52000000")

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onClicked: Shell.dispatch("sidebar.toggle")
            onWheel: wheel => wheel.accepted = true
        }
    }

    // Beside the right panel shown as a sheet: a click there puts it away.
    Rectangle {
        id: panelScrim
        objectName: "panelScrim"
        visible: layout.panelSheet && panelView.visible && panelView.open
        x: sidebarScrim.visible ? sidebarScrim.x : 0
        y: panelView.parent.y + layout.headerHeight
        width: parent.width - panelView.width - x
        height: panelView.height
        color: Theme.palette.color("scrim", "#52000000")

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onClicked: Shell.dispatch("rightPanel.toggle")
            onWheel: wheel => wheel.accepted = true
        }
    }

    // A device floated over the chat: it keeps streaming and taking touches
    // while the right panel shows something else, or is closed.
    Rectangle {
        id: floatingDevice

        objectName: "floatingDevice"
        visible: (Shell.state.panel?.floatingDevice ?? null) !== null && !panelView.open
        width: 224
        height: 452
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: 16
        anchors.bottomMargin: 16
        radius: 8
        color: Theme.palette.color("surface", "#0f0f11")
        border.color: Theme.palette.color("border", "#27272a")
        z: 3

        DragHandler {
            target: floatingDevice
            xAxis.enabled: true
            yAxis.enabled: true
            onActiveChanged: {
                if (active) {
                    floatingDevice.anchors.right = undefined;
                    floatingDevice.anchors.bottom = undefined;
                }
            }
        }

        DevicePanel {
            anchors.fill: parent
            anchors.topMargin: 24
            source: Panel.device
        }

        Item {
            width: parent.width
            height: 24

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Device")
                color: Theme.palette.color("textMuted", "#8b8b93")
                font.pixelSize: Math.round(11 * Theme.fontScale)
            }
            ShellButton {
                objectName: "floatingDeviceOpen"
                anchors.right: parent.right
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                subtle: true
                iconName: "panel-right"
                Accessible.name: qsTr("Open in right panel")
                onClicked: Shell.dispatch("rightPanel.unfloat")
            }
        }
    }

    // In the window's corner, level with the buttons of the band under it.
    WindowControls {
        id: windowButtonsView
        objectName: "windowButtons"
        visible: layout.windowButtons
        window: layout.window
        buttonWidth: 32
        buttonHeight: 28
        anchors.right: parent.right
        anchors.rightMargin: 4
        y: layout.corner === "centre" && workspaceView.visible ? 12 : layout.corner === "details" ? 8 : 4
    }

    ProjectFolderDrop {
        anchors.fill: parent
    }

    // Toasts stack from the top right, under the header strip (or the band
    // a page without one has): clear of the
    // window controls, the composer and the terminal drawer's toolbar. Over
    // a right-hand panel they cover its top, which is the price of a stack
    // that never moves with the panels.
    Notifications {
        objectName: "toasts"
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: body.y + centre.y + layout.headerHeight + 16
        anchors.rightMargin: 16
        opaque: true
        maximumHeight: parent.height - anchors.topMargin - 16
    }
}
