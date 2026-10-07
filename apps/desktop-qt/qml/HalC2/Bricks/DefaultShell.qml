import QtQuick
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// Built-in layout: sidebar, header strip, timeline, composer. A user's
// ~/.hal-c2/shell/shell.qml replaces this file wholesale; it is also the
// fallback when that file fails to load.
// Frameless windows get their drag handle and window buttons from the
// sidebar band and the header strip rather than a separate title bar.
ShellWindow {
    id: root

    // Local QML extensions can customize one brick without copying the layout.
    property alias sidebar: sidebarView
    property alias composer: composerView
    property alias workspace: workspaceView
    property alias centreView: centreHost
    property alias terminalDrawer: terminalView
    property alias rightPanel: panelView
    property alias toolbar: toolbarLoader.sourceComponent
    property alias navigationPanel: sidebarExtension.sourceComponent

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
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
                columns: sidebarExtension.active && root.width >= 1100 ? 2 : 1
                rowSpacing: 0
                columnSpacing: 0
                visible: !root.settingsActive && !root.sidebarCollapsed

                Sidebar {
                    id: sidebarView
                    objectName: "threadSidebar"
                    // The width while its edge is dragged, else the layout's.
                    property int dragWidth: -1
                    readonly property int shownWidth: dragWidth >= 0 ? dragWidth : root.sidebarWidth

                    Layout.fillHeight: true
                    Layout.fillWidth: true
                    Layout.preferredWidth: shownWidth
                    Layout.minimumWidth: 0
                    showBrand: true
                    window: root

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
                            if (width >= 0 && width !== root.sidebarWidth)
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
                objectName: "folderExplorerHost"
                Layout.fillHeight: true
                Layout.preferredWidth: active ? 340 : 0
                active: (Shell.state.folders?.open ?? false) && !root.settingsActive
                visible: active
                sourceComponent: FolderExplorer {}
            }

            SettingsNav {
                objectName: "settingsNav"
                Layout.fillHeight: true
                Layout.preferredWidth: 256
                visible: root.settingsActive
            }

            ColumnLayout {
                id: centre

                Layout.fillWidth: true
                Layout.fillHeight: true
                // A maximized right panel covers the thread.
                visible: !panelView.maximized
                spacing: 0

                Workspace {
                    id: workspaceView
                    objectName: "workspace"

                    Layout.fillWidth: true
                    visible: ready
                    sidebarToggle: root.sidebarCollapsed
                    panelToggle: panelView.available ? panelView.open : null
                    detailsToggle: Shell.state.panel ? Shell.state.panel.detailsOpen === true : null
                    window: root
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
                    section: root.settingsSection
                    visible: root.settingsActive
                }

                // The route's centre: a thread, draft, home, pull requests or usage.
                CentreHost {
                    id: centreHost
                    objectName: "centreHost"

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    kind: root.route?.kind ?? ""
                    visible: !root.settingsActive
                }

                Composer {
                    id: composerView

                    Layout.fillWidth: true
                    visible: ready && !root.settingsActive
                    conversationScrolled: centreHost.conversationScrolled
                }

                TerminalDrawer {
                    id: terminalView

                    Layout.fillWidth: true
                }
            }

            // The thread details column (threadPanel.toggle), beside the thread.
            ThreadDetailsPanel {
                Layout.fillHeight: true
                Layout.preferredWidth: implicitWidth
                details: Shell.state.panel?.details ?? null
                visible: details !== null && !panelView.maximized
            }

            RightPanel {
                id: panelView

                Layout.fillHeight: true
                Layout.fillWidth: maximized
                ownToggle: false
                canMaximize: true
                Layout.preferredWidth: implicitWidth
                // The thread keeps room of its own.
                maximumWidth: root.width - (navigation.visible ? navigation.width : 0) - minimumWidth
                visible: available
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

    ProjectFolderDrop {
        anchors.fill: parent
    }

    Notifications {
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        anchors.bottomMargin: 180
        anchors.rightMargin: 16
    }
}
