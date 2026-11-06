import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// A thread, or a new thread's draft: the way back and its title, the route's
// centre (the timeline, or the draft's opening line that picks its project),
// and the composer, which carries the thread's approvals and questions. The
// tabs the desktop draws beside the thread that a phone shows (its Files, its
// Diff, its linked pull requests and a pull request's review) take the screen
// under the same bar; the way back closes them (MobileShell.stepBack), and a
// reply's changed files open the Diff here as there. A line of the diff is
// tapped to comment on it, and the comment waits on the
// composer for the next message. The pull requests are the phone's git
// overview: where they are linked, refreshed and opened, and where a thread is
// started on one. Files dropped anywhere on the centre or the composer join
// the draft. Above the composer, the subagents of the turn while it works
// (TurnAgents), which open to their list.
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
        return kind === "files" || kind === "diff" || kind === "pull-requests" || kind === "pull-request" ? kind : "";
    }
    readonly property bool panelShown: panelKind.length > 0
    readonly property bool muted: notifications !== null && (notifications.muted ?? []).indexOf(threadKey) >= 0
    // How much of the screen's bottom the composer takes: what lies over the
    // screen from below (the shell's toasts) stays above it.
    readonly property real composerHeight: composerView.visible ? composerView.height : 0

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
                objectName: "openDiff"
                visible: !screen.panelShown && screen.threadKey.length > 0
                iconName: "file-diff"
                label: qsTr("Diff")
                onClicked: Shell.dispatch("rightPanel.add", { kind: "diff" })
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
        // A thread with no conversation yet suggests what to ask, as the web phone did.
        Binding {
            target: centre.item as ThreadView
            property: "emptyText"
            value: qsTr("No conversation yet")
        }
        Binding {
            target: centre.item as ThreadView
            property: "emptyHint"
            value: qsTr("Ask the agent to inspect the repo, run a command, or continue the active thread.")
        }

        Loader {
            Layout.fillWidth: true
            Layout.fillHeight: true
            active: screen.panelShown
            visible: active
            sourceComponent: ({ files: files, diff: diff, "pull-requests": pullRequests })[screen.panelKind] ?? review
        }

        // The subagents of the turn while they or the turn work: "2 of 3
        // agents working", which opens their list.
        ItemDelegate {
            objectName: "agentsStatus"
            Layout.fillWidth: true
            visible: turnAgents.summary.length > 0 && !screen.panelShown
            implicitHeight: 36
            text: turnAgents.summary
            icon.name: "bot"
            onClicked: agentsSheet.open()

            contentItem: Label {
                text: parent.text
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
                color: Theme.palette.color("textMuted", "#a1a1aa")
            }
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

    TurnAgents {
        id: turnAgents

        timeline: screen.threadKey.length > 0 ? Threads.timeline : null
        active: agentsSheet.visible
    }

    // The turn's subagents, each with its state and how long it took; one with
    // a thread of its own opens it, one the provider manages works in this
    // conversation (ThreadAgentsSheet).
    Popup {
        id: agentsSheet

        objectName: "agentsSheet"
        parent: Overlay.overlay
        modal: true
        focus: true
        x: (parent.width - width) / 2
        y: parent.height - height
        width: Math.min(parent.width, 520)
        height: Math.min(implicitHeight, parent.height - 24)
        padding: 12

        background: MobileSurface {}
        Overlay.modal: Rectangle {
            color: Qt.rgba(0, 0, 0, 0.5)
        }

        contentItem: ColumnLayout {
            spacing: 8

            Label {
                Layout.fillWidth: true
                text: qsTr("Agents")
                font.weight: Font.DemiBold
                color: Theme.palette.color("text", "#e4e4e7")
            }

            Label {
                Layout.fillWidth: true
                visible: turnAgents.count === 0
                text: qsTr("No agents in this turn.")
                color: Theme.palette.color("textMuted", "#a1a1aa")
            }

            ListView {
                objectName: "agentsList"
                Layout.fillWidth: true
                Layout.fillHeight: true
                implicitHeight: Math.min(contentHeight, 420)
                clip: true
                model: turnAgents

                delegate: ItemDelegate {
                    id: agent

                    required property string agentId
                    required property string title
                    required property string statusLabel
                    required property string elapsed
                    required property string thread
                    readonly property bool opens: thread.length > 0

                    objectName: "agent:" + title
                    width: ListView.view.width
                    enabled: opens
                    onClicked: {
                        agentsSheet.close();
                        Shell.dispatch("rightPanel.openThread", { threadKey: agent.thread });
                    }

                    contentItem: RowLayout {
                        spacing: 12

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2

                            Label {
                                objectName: "agentTitle"
                                Layout.fillWidth: true
                                text: agent.title
                                elide: Text.ElideRight
                                font.weight: Font.Medium
                                color: Theme.palette.color("text", "#e4e4e7")
                            }
                            Label {
                                objectName: "agentStatus"
                                Layout.fillWidth: true
                                text: agent.opens ? agent.statusLabel : qsTr("%1 · Its work appears in the conversation").arg(agent.statusLabel)
                                elide: Text.ElideRight
                                color: Theme.palette.color("textMuted", "#a1a1aa")
                            }
                        }
                        Label {
                            objectName: "agentElapsed"
                            visible: text.length > 0
                            text: agent.elapsed
                            font.features: {
                                "tnum": 1
                            }
                            color: Theme.palette.color("textMuted", "#a1a1aa")
                        }
                        ShellChevron {
                            visible: agent.opens
                            direction: "right"
                            size: 12
                            color: Theme.palette.color("textMuted", "#a1a1aa")
                        }
                    }
                }
            }
        }
    }

    Component {
        id: files

        FilesPanel {
            objectName: "filesPanel"
            source: Panel.files
        }
    }

    Component {
        id: diff

        DiffPanel {
            source: Panel.diff
            touchLines: true
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
