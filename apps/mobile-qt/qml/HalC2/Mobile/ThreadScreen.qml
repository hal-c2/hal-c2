import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// A thread, or a new thread's draft: the way back and its title, the route's
// centre (the timeline, or the draft's opening line that picks its project),
// and the composer, which carries the thread's approvals and questions. The
// tabs the desktop draws beside the thread that a phone shows (its Files, its
// linked pull requests and a pull request's review) take the screen under the
// same bar; the way back closes them (MobileShell.stepBack). The pull requests
// are the phone's git overview: where they are linked, refreshed and opened,
// and where a thread is started on one. Files dropped anywhere on the centre
// or the composer join the draft.
Item {
    id: screen

    readonly property var route: Shell.state.route ?? null
    readonly property var notifications: Shell.state.notifications ?? null
    readonly property string threadKey: route !== null && route.kind === "thread" ? (route.threadKey ?? "") : ""
    readonly property var panel: Shell.state.panel ?? null
    // The kind of the right panel's tab that takes the screen, "" for none.
    readonly property string panelKind: {
        if (panel === null || !panel.isOpen)
            return "";
        const kind = (panel.activeId ?? "").split(":")[0];
        return kind === "files" || kind === "pull-requests" || kind === "pull-request" ? kind : "";
    }
    readonly property bool panelShown: panelKind.length > 0
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
                visible: !screen.panelShown && screen.threadKey.length > 0
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
                objectName: "openPullRequests"
                visible: !screen.panelShown && screen.threadKey.length > 0
                iconName: "git-pull-request"
                label: qsTr("Pull requests")
                onClicked: Shell.dispatch("rightPanel.add", { kind: "pull-requests" })
            }

            // A new thread on a pull request, checked out here or in a worktree.
            MobileIconButton {
                objectName: "startPullRequestThread"
                visible: screen.panelKind === "pull-requests"
                iconName: "git-branch"
                label: qsTr("Start a thread on a pull request")
                onClicked: Shell.dispatch("pullRequestThread.open", {})
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
            visible: !screen.panelShown
            kind: screen.route?.kind ?? ""

            // A finger has no hover: a message's actions always show.
            Binding {
                target: centre.item
                when: centre.item instanceof ThreadView
                property: "alwaysShowMeta"
                value: true
            }
        }

        Loader {
            Layout.fillWidth: true
            Layout.fillHeight: true
            active: screen.panelShown
            visible: active
            sourceComponent: screen.panelKind === "files" ? files : screen.panelKind === "pull-requests" ? pullRequests : review
        }

        Composer {
            id: composerView

            objectName: "composer"
            takesDrops: false
            Layout.fillWidth: true
            visible: ready && !screen.panelShown
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

    Component {
        id: files

        FilesPanel {
            objectName: "filesPanel"
            source: Panel.files
        }
    }

    Component {
        id: pullRequests

        PullRequestsPanel {
            source: Panel.pullRequests
        }
    }

    Component {
        id: review

        PullRequestReviewPanel {
            source: Panel.review
        }
    }
}
