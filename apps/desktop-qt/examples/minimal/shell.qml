import QtQuick
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// Copy to ~/.hal-c2/shell/shell.qml and edit; the app reloads on save.
// Bricks come from HalC2.Bricks, data from the HalC2.Shell singletons
// (Shell.state, Shell.dispatch, Theme.*, Runtime.*). ShellWindow brings the
// window boilerplate, the error overlay and the window commands.
ShellWindow {
    id: root

    // A page an MC plugin added is showing: it takes the place of the thread.
    readonly property bool pluginTab: (root.route?.tab ?? "threads") !== "threads" && !root.settingsActive

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Threads, then a tab per page an MC plugin adds; hidden while there are none.
        ShellTabs {
            Layout.fillWidth: true
            visible: pages.length > 0 && !root.settingsActive
            window: root
            // The title bar below carries the window buttons.
            windowControls: false
        }

        RowLayout {
            id: columns

            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            Sidebar {
                Layout.fillHeight: true
                Layout.preferredWidth: root.sidebarCollapsed ? 0 : 256
                Layout.minimumWidth: 0
                visible: !root.settingsActive && (!root.sidebarCollapsed || width > 0)
                showBrand: true
                window: root

                Behavior on Layout.preferredWidth {
                    NumberAnimation {
                        duration: 220
                        easing.type: Easing.OutCubic
                    }
                }
            }

            SettingsNav {
                Layout.fillHeight: true
                Layout.preferredWidth: 256
                visible: root.settingsActive
            }

            ColumnLayout {
                id: thread

                Layout.fillWidth: true
                Layout.fillHeight: true
                // The thread keeps room of its own (DefaultLayout's
                // threadMinimumWidth); the right panel gives way instead.
                Layout.minimumWidth: 360
                visible: !root.pluginTab
                spacing: 0

                Workspace {
                    Layout.fillWidth: true
                    visible: ready
                    sidebarToggle: root.sidebarCollapsed
                    panelToggle: rightPanel.available ? rightPanel.open : null
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
                    visible: !root.settingsActive
                }

                Composer {
                    Layout.fillWidth: true
                    visible: ready && !root.settingsActive
                }

                TerminalDrawer {
                    Layout.fillWidth: true
                }
            }

            PluginPages {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: root.pluginTab
            }

            RightPanel {
                id: rightPanel

                Layout.fillHeight: true
                Layout.preferredWidth: implicitWidth
                // What the thread leaves it, so a narrower window or a
                // wider drag takes no room from the thread.
                maximumWidth: Math.max(minimumWidth, columns.width - thread.x - thread.Layout.minimumWidth)
                ownToggle: false
                visible: available && !root.pluginTab
            }
        }

        // Title bar at the bottom instead of the top.
        TitleBar {
            Layout.fillWidth: true
            visible: Theme.frameless
            window: root
        }
    }

    Notifications {
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        anchors.bottomMargin: 180
        anchors.rightMargin: 16
    }
}
