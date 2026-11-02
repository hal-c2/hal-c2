import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// A thread, or a new thread's draft: the way back and its title, the route's
// centre (the timeline, or the draft's opening line that picks its project),
// and the composer, which carries the thread's approvals and questions. The
// Files tab, which the desktop draws beside the thread, takes the screen under
// the same bar; the way back closes it (MobileShell.stepBack). Files dropped
// anywhere on the centre or the composer join the draft.
Item {
    id: screen

    readonly property var route: Shell.state.route ?? null
    readonly property var notifications: Shell.state.notifications ?? null
    readonly property string threadKey: route !== null && route.kind === "thread" ? (route.threadKey ?? "") : ""
    readonly property var panel: Shell.state.panel ?? null
    readonly property bool filesOpen: panel !== null && panel.isOpen && panel.activeId === "files"
    readonly property bool muted: notifications !== null && (notifications.muted ?? []).indexOf(threadKey) >= 0

    signal backRequested

    objectName: "threadScreen"

    ColumnLayout {
        id: column

        anchors.fill: parent
        spacing: 0

        MobileBar {
            Layout.fillWidth: true
            canGoBack: true
            title: screen.route !== null && screen.route.title ? screen.route.title : qsTr("Thread")
            onBackRequested: screen.backRequested()

            // This thread's alerts on this phone, which the MC holds back while muted.
            MobileIconButton {
                objectName: screen.muted ? "unmuteAlerts" : "muteAlerts"
                visible: screen.notifications?.supported === true && screen.threadKey.length > 0
                iconName: screen.muted ? "bell-off" : "bell"
                label: screen.muted ? qsTr("Unmute alerts for this thread") : qsTr("Mute alerts for this thread")
                onClicked: Shell.dispatch("alerts.setMuted", { key: screen.threadKey, muted: !screen.muted })
            }

            MobileIconButton {
                objectName: "openFiles"
                visible: !screen.filesOpen && screen.threadKey.length > 0
                iconName: "files"
                label: qsTr("Files")
                onClicked: Shell.dispatch("rightPanel.add", { kind: "files" })
            }

            // A tap opens the terminal; held, its menu of terminals and scripts.
            MobileIconButton {
                objectName: "threadTerminal"
                visible: Terminals.available
                iconName: "terminal"
                label: qsTr("Open the terminal: %1").arg((Shell.state.mobileTerminal ?? {}).label ?? "")
                onClicked: Shell.dispatch("terminal.toggle")
                onPressAndHold: Shell.dispatch("mobileTerminal.menu", {})
            }

            MobileIconButton {
                objectName: "threadMenu"
                iconName: "ellipsis"
                label: qsTr("Thread actions")
                // The menu the desktop's title opens: the thread's, or a draft's.
                onClicked: {
                    const point = mapToItem(null, width, height);
                    Shell.dispatch("workspace.titleMenu", { x: point.x, y: point.y });
                }
            }
        }

        CentreHost {
            id: centre

            objectName: "centreHost"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !screen.filesOpen
            kind: screen.route?.kind ?? ""
        }

        Loader {
            Layout.fillWidth: true
            Layout.fillHeight: true
            active: screen.filesOpen
            visible: active
            sourceComponent: FilesPanel {
                objectName: "filesPanel"
                source: Panel.files
            }
        }

        Composer {
            id: composerView

            objectName: "composer"
            takesDrops: false
            Layout.fillWidth: true
            visible: ready && !screen.filesOpen
            conversationScrolled: centre.conversationScrolled
        }
    }

    ConversationDrop {
        y: centre.y
        width: column.width
        height: composerView.y + composerView.height - centre.y
        visible: composerView.visible
        composer: composerView
    }
}
