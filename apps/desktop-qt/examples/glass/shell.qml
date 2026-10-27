import QtQuick
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// Graphite glass: one rounded window with a hairline edge, traffic lights in
// the corner, a translucent sidebar for the compositor to blur behind, and
// an opaque content column with a unified toolbar — the shape of a Mac app.
ShellWindow {
    id: root

    readonly property color canvas: Theme.palette.color("canvas", "#1e1e1e")
    readonly property color line: Theme.palette.color("border", "#ffffff14")
    readonly property real corner: Theme.radius
    // How far the toolbar's leading edge stays clear of the traffic lights
    // once the sidebar folds away and they end up over the content column.
    readonly property real lightsInset: root.sidebarCollapsed && !root.settingsActive ? 66 : 0
    // A page an MC plugin added is showing: it takes the place of the thread.
    readonly property bool pluginTab: (root.route?.tab ?? "threads") !== "threads" && !root.settingsActive

    width: 1360
    height: 860

    Rectangle {
        id: frame

        anchors.fill: parent
        radius: root.corner
        color: "transparent"
        border.color: root.line
        border.width: 1

        RowLayout {
            id: columns

            anchors.fill: parent
            anchors.margins: 1
            spacing: 0

            // Sidebar column: the theme's sidebar colour carries the alpha, so
            // the desktop shows through the blur; the band under the lights
            // drags the window.
            Rectangle {
                id: sidebarColumn

                Layout.fillHeight: true
                Layout.preferredWidth: root.sidebarCollapsed && !root.settingsActive ? 0 : 248
                Layout.minimumWidth: 0
                visible: !(root.sidebarCollapsed && !root.settingsActive) || width > 0
                color: Theme.palette.color("sidebar", "#202020b8")
                topLeftRadius: root.corner - 1
                bottomLeftRadius: root.corner - 1
                clip: true

                Behavior on Layout.preferredWidth {
                    NumberAnimation {
                        duration: 220
                        easing.type: Easing.OutCubic
                    }
                }

                Item {
                    width: 248
                    height: parent.height

                    Item {
                        id: lightsBand

                        width: parent.width
                        height: 52

                        DragHandler {
                            target: null
                            onActiveChanged: if (active)
                                root.startSystemMove()
                        }

                        TapHandler {
                            onDoubleTapped: root.visibility === Window.Maximized ? root.showNormal() : root.showMaximized()
                        }
                    }

                    Sidebar {
                        anchors.fill: parent
                        anchors.topMargin: lightsBand.height
                        visible: !root.settingsActive
                        color: "transparent"
                    }

                    SettingsNav {
                        anchors.fill: parent
                        anchors.topMargin: lightsBand.height
                        visible: root.settingsActive
                        color: "transparent"
                    }
                }

                Rectangle {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 1
                    color: root.line
                }
            }

            // Content column: toolbar, page, composer, all on one opaque
            // canvas so text stays crisp over whatever the desktop shows.
            Rectangle {
                id: thread

                Layout.fillWidth: true
                Layout.fillHeight: true
                // The thread keeps room of its own (DefaultLayout's
                // threadMinimumWidth); the right panel gives way instead.
                Layout.minimumWidth: 360
                color: root.canvas
                topLeftRadius: sidebarColumn.visible ? 0 : root.corner - 1
                bottomLeftRadius: sidebarColumn.visible ? 0 : root.corner - 1
                topRightRadius: panelColumn.visible ? 0 : root.corner - 1
                bottomRightRadius: panelColumn.visible ? 0 : root.corner - 1

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 0

                    // Threads, then a tab per page an MC plugin adds; hidden while
                    // there are none. It drags the window like the toolbar below.
                    ShellTabs {
                        Layout.fillWidth: true
                        Layout.leftMargin: root.lightsInset
                        visible: pages.length > 0 && !root.settingsActive
                        color: "transparent"
                        window: root
                        windowControls: false
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 52
                        visible: !root.pluginTab

                        DragHandler {
                            target: null
                            onActiveChanged: if (active)
                                root.startSystemMove()
                        }

                        Workspace {
                            anchors.fill: parent
                            anchors.leftMargin: root.lightsInset
                            visible: ready
                            color: "transparent"
                            sidebarToggle: root.sidebarCollapsed
                            panelToggle: rightPanel.available ? rightPanel.open : null

                            Behavior on anchors.leftMargin {
                                NumberAnimation {
                                    duration: 220
                                    easing.type: Easing.OutCubic
                                }
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 1
                        color: root.line
                    }

                    PluginPages {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        visible: root.pluginTab
                    }

                    SettingsHost {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        section: root.settingsSection
                        visible: root.settingsActive
                    }

                    // The route's centre: a thread, draft, home, pull requests or usage.
                    CentreHost {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        kind: root.route?.kind ?? ""
                        visible: !root.settingsActive && !root.pluginTab
                    }

                    Composer {
                        Layout.fillWidth: true
                        visible: ready && !root.settingsActive && !root.pluginTab
                        color: "transparent"
                    }

                    TerminalDrawer {
                        Layout.fillWidth: true
                        visible: open && !root.pluginTab
                    }
                }
            }

            Rectangle {
                id: panelColumn

                Layout.fillHeight: true
                Layout.preferredWidth: rightPanel.implicitWidth
                visible: rightPanel.available && rightPanel.implicitWidth > 0 && !root.pluginTab
                clip: true
                color: Theme.palette.color("chrome", "#262626")
                topRightRadius: root.corner - 1
                bottomRightRadius: root.corner - 1

                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 1
                    color: root.line
                }

                RightPanel {
                    id: rightPanel

                    anchors.fill: parent
                    anchors.leftMargin: 1
                    // What the thread leaves it, so a narrower window or a
                    // wider drag takes no room from the thread.
                    maximumWidth: Math.max(minimumWidth, columns.width - thread.x - thread.Layout.minimumWidth)
                    ownToggle: false
                    color: "transparent"
                }
            }
        }

        // Inner highlight along the top edge, the way a Mac window catches light.
        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 1
            height: 1
            color: Qt.rgba(1, 1, 1, 0.06)
        }

        WindowControls {
            x: 14
            y: 20
            window: root
            trafficLights: true
            order: ["close", "minimize", "maximize"]
        }
    }

    Notifications {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 64
        anchors.rightMargin: 20
    }
}
