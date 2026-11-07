pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The right panel's Pull request review tab: one linked pull request from a
// PullRequestReview (Panel.review), in three parts: its description and
// checks, its conversation (commenting, reviewing, resolving threads), and
// its code, drawn by DiffPanel with a Viewed box per file. The header copies
// the number, opens it on the host and reads it again. Offline, what was read
// stays and nothing is sent.
//
//   PullRequestReviewPanel { anchors.fill: parent; source: Panel.review }
Rectangle {
    id: root

    property var source: null
    // overview, conversation or code
    property string section: "overview"

    readonly property var detail: source?.detail ?? ({})
    readonly property var threads: source?.threads ?? null
    readonly property bool online: source !== null && source.online
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color borderColor: Theme.palette.color("border", "#27272a")
    readonly property color errorColor: Theme.palette.color("errorForeground", "#ef4444")
    readonly property color successColor: Theme.palette.color("success", "#22c55e")
    readonly property color warningColor: Theme.palette.color("warningForeground", "#f59e0b")

    function stateColor(state) {
        if (state === "open")
            return root.successColor;
        if (state === "merged")
            return Theme.palette.color("merged", "#a855f7");
        if (state === "closed")
            return root.errorColor;
        return root.muted;
    }
    function checkColor(status) {
        if (status === "success")
            return root.successColor;
        if (status === "failure" || status === "action-required" || status === "cancelled")
            return root.errorColor;
        if (status === "pending")
            return root.warningColor;
        return root.muted;
    }

    objectName: "pullRequestReviewPanel"
    color: Theme.palette.color("surface", "#0f0f11")

    // What DiffPanel reads of a source, for the pull request's code.
    QtObject {
        id: code

        readonly property var model: root.source?.model ?? null
        readonly property string status: root.source?.codeStatus ?? "idle"
        readonly property string message: root.source?.codeStatus === "loading" ? qsTr("Loading the code…") : root.source?.codeMessage ?? ""
        readonly property bool hasTurns: false
        readonly property var viewedPaths: root.source?.viewedPaths ?? []
        property bool wrap: false

        // DiffPanel follows it; the review never asks for a row.
        signal revealRow(int row)

        function reload() {
            root.source.reload();
        }
        function setViewed(path, viewed) {
            root.source.setViewed(path, viewed);
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Title, where it stands, and what can be done with it.
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 8
            spacing: Theme.space.sm

            ShellIcon {
                name: root.detail.state === "merged" ? "git-merge" : root.detail.state === "closed" ? "circle-x" : "git-pull-request"
                size: 14
                color: root.stateColor(root.detail.state ?? "")
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                Text {
                    objectName: "reviewTitle"
                    Layout.fillWidth: true
                    text: root.detail.title ?? qsTr("Pull request #%1").arg(root.source?.number ?? 0)
                    elide: Text.ElideRight
                    color: root.foreground
                    font.pixelSize: Theme.type.body.size
                    font.weight: Font.Medium
                }
                Text {
                    Layout.fillWidth: true
                    text: ["#" + (root.source?.number ?? 0), root.detail.stateLabel ?? "", root.detail.author ?? "", root.detail.branches ?? ""].filter(part => part.length > 0).join(" · ")
                    elide: Text.ElideRight
                    color: root.muted
                    font.pixelSize: Theme.type.caption.size

                    // The number's menu: copy its link, or open it on its host.
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        enabled: (root.detail.url ?? "").length > 0
                        // ljos-allow(focus-pointer-only): the header's Open and Copy buttons offer the same from the keyboard
                        onTapped: eventPoint => Shell.dispatch("pullRequest.linkMenu", {
                                url: root.detail.url,
                                x: eventPoint.scenePosition.x,
                                y: eventPoint.scenePosition.y
                            })
                    }
                }
            }
            // PullRequestThreadLinks: how many threads work on it, which opens
            // the palette on them, and linking it to this thread or another.
            ShellButton {
                objectName: "reviewLinkedThreads"
                subtle: true
                iconName: "message-square"
                text: root.threads && root.threads.count > 0 ? root.threads.count : ""
                visible: root.threads !== null && root.threads.available && root.threads.count > 0
                Accessible.name: root.threads?.label ?? ""
                ToolTip.visible: hovered
                ToolTip.text: qsTr("%1. Search in the command palette.").arg(Accessible.name)
                onClicked: root.threads.search()
            }
            ShellButton {
                objectName: "reviewThreadMenu"
                subtle: true
                iconName: "link"
                visible: root.threads !== null && root.threads.available
                enabled: root.online && !(root.threads?.pending ?? true)
                Accessible.name: qsTr("Linked threads")
                ToolTip.visible: hovered
                ToolTip.text: Accessible.name
                onClicked: threadMenu.open()

                ShellMenu {
                    id: threadMenu

                    y: parent.height

                    ShellMenuItem {
                        objectName: "reviewThreadToggle"
                        text: root.threads?.menuLabel ?? ""
                        iconName: "link"
                        enabled: !(root.threads?.pending ?? true)
                        onTriggered: root.threads.toggleHere()
                    }
                    ShellMenuItem {
                        objectName: "reviewThreadPick"
                        text: qsTr("Link to another thread…")
                        iconName: "message-square-plus"
                        enabled: !(root.threads?.pending ?? true)
                        onTriggered: root.threads.pickerOpen = true
                    }
                }
            }
            ShellButton {
                objectName: "reviewCopyNumber"
                subtle: true
                iconName: "hash"
                Accessible.name: qsTr("Copy PR number")
                ToolTip.visible: hovered
                ToolTip.text: Accessible.name
                onClicked: root.source.copyNumber()
            }
            ShellButton {
                subtle: true
                iconName: "external-link"
                enabled: (root.detail.url ?? "").length > 0
                Accessible.name: qsTr("Open in browser")
                ToolTip.visible: hovered
                ToolTip.text: Accessible.name
                onClicked: root.source.openOnHost()
            }
            ShellButton {
                objectName: "reviewReload"
                subtle: true
                iconName: "refresh-cw"
                enabled: root.online
                Accessible.name: qsTr("Refresh pull request")
                ToolTip.visible: hovered
                ToolTip.text: Accessible.name
                onClicked: root.source.reload()
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 8
            Layout.rightMargin: 8
            Layout.bottomMargin: Theme.space.sm
            spacing: 4

            Repeater {
                model: [
                    {
                        id: "overview",
                        label: qsTr("Overview")
                    },
                    {
                        id: "conversation",
                        label: qsTr("Conversation (%1)").arg(root.source?.conversation.length ?? 0)
                    },
                    {
                        id: "code",
                        label: (root.source?.model?.fileCount ?? 0) > 0 ? qsTr("Code (%1/%2 viewed)").arg(root.source.viewedCount).arg(root.source.model.fileCount) : qsTr("Code")
                    }
                ]

                delegate: ShellButton {
                    required property var modelData

                    objectName: "reviewSection-" + modelData.id
                    subtle: root.section !== modelData.id
                    checked: root.section === modelData.id
                    text: modelData.label
                    onClicked: root.section = modelData.id
                }
            }
            Item {
                Layout.fillWidth: true
            }
        }

        Text {
            objectName: "reviewOffline"
            Layout.fillWidth: true
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            Layout.bottomMargin: Theme.space.sm
            visible: root.source !== null && !root.online
            wrapMode: Text.Wrap
            text: qsTr("This environment is unreachable. The pull request shows as last read.")
            color: root.warningColor
            font.pixelSize: Theme.type.meta.size
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: root.borderColor
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ColumnLayout {
                objectName: "reviewMessage"
                anchors.centerIn: parent
                width: parent.width - 32
                visible: root.section !== "code" && (root.source?.status ?? "idle") !== "ready"
                spacing: Theme.space.sm

                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: root.source?.status === "error" ? root.source.message : root.source?.status === "loading" ? qsTr("Loading the pull request…") : ""
                    color: root.source?.status === "error" ? root.errorColor : root.muted
                    font.pixelSize: Theme.type.body.size
                }
                ShellButton {
                    Layout.alignment: Qt.AlignHCenter
                    visible: root.source?.status === "error" && root.online
                    text: qsTr("Try again")
                    onClicked: root.source.reload()
                }
            }

            // Description, labels, reviewers and checks.
            Flickable {
                objectName: "reviewOverview"
                anchors.fill: parent
                visible: root.section === "overview" && root.source?.status === "ready"
                clip: true
                contentHeight: overview.implicitHeight + 24
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: overview

                    x: 12
                    y: 12
                    width: parent.width - 24
                    spacing: Theme.space.sm

                    // The host's stack this pull request is a layer of: where
                    // it sits, and merging or rebasing the stack, which ask first.
                    ColumnLayout {
                        id: stackSection

                        readonly property var stack: root.source?.stack ?? ({})
                        readonly property bool shown: (stack.size ?? 0) > 0

                        objectName: "reviewStack"
                        Layout.fillWidth: true
                        visible: shown
                        spacing: Theme.space.sm

                        Text {
                            objectName: "reviewStackTitle"
                            Layout.fillWidth: true
                            text: stackSection.shown ? qsTr("Stack #%1 · layer %2 of %3 onto %4").arg(stackSection.stack.number).arg(stackSection.stack.position).arg(stackSection.stack.size).arg(stackSection.stack.base) : ""
                            color: root.foreground
                            font.pixelSize: Theme.type.meta.size
                            font.weight: Font.Medium
                            elide: Text.ElideRight
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            visible: stackSection.stack.stale === true
                            spacing: Theme.space.sm

                            Text {
                                objectName: "reviewStackNotice"
                                Layout.fillWidth: true
                                text: stackSection.stack.notice ?? ""
                                color: root.warningColor
                                font.pixelSize: Theme.type.meta.size
                                wrapMode: Text.Wrap
                            }
                            ShellButton {
                                objectName: "reviewStackRetry"
                                text: qsTr("Retry stack refresh")
                                onClicked: root.source.retryStack()
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.space.sm

                            ShellButton {
                                objectName: "reviewStackMerge"
                                text: qsTr("Merge stack (%1)").arg(stackSection.stack.mergeCount ?? 0)
                                enabled: stackSection.stack.canMerge === true && !(root.source?.busy ?? false)
                                onClicked: root.source.requestStackMerge("")
                            }
                            ShellButton {
                                objectName: "reviewStackRebase"
                                text: qsTr("Rebase stack")
                                enabled: stackSection.stack.canRebase === true && !(root.source?.busy ?? false)
                                onClicked: root.source.requestStackRebase()
                            }
                            Item {
                                Layout.fillWidth: true
                            }
                        }
                    }

                    // Merging, where the host and the viewer's rights allow it:
                    // the default method, or another the repository allows.
                    RowLayout {
                        Layout.fillWidth: true
                        visible: root.detail.canMerge === true
                        spacing: Theme.space.sm

                        ShellButton {
                            objectName: "reviewMerge"
                            primary: true
                            text: root.source?.busy ? qsTr("Merging…") : qsTr("Merge pull request")
                            enabled: root.online && !(root.source?.busy ?? false)
                            onClicked: root.source.merge("")
                        }
                        ShellButton {
                            objectName: "reviewMergeMethod"
                            visible: (root.detail.mergeMethods ?? []).length > 1
                            chevron: true
                            text: qsTr("Method")
                            enabled: root.online && !(root.source?.busy ?? false)
                            onClicked: mergeMethods.open()

                            ShellMenu {
                                id: mergeMethods

                                y: parent.height

                                Instantiator {
                                    model: root.detail.mergeMethods ?? []
                                    delegate: ShellMenuItem {
                                        required property string modelData

                                        text: modelData === "squash" ? qsTr("Squash and merge") : modelData === "rebase" ? qsTr("Rebase and merge") : qsTr("Create a merge commit")
                                        onTriggered: root.source.merge(modelData)
                                    }
                                    onObjectAdded: (index, object) => mergeMethods.insertItem(index, object)
                                    onObjectRemoved: (index, object) => mergeMethods.removeItem(object)
                                }
                            }
                        }
                        Item {
                            Layout.fillWidth: true
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: (root.detail.behindBy ?? 0) > 0
                        wrapMode: Text.Wrap
                        text: (root.detail.behindBy ?? 0) === 1 ? qsTr("This branch is %n commit behind its base.", "", 1) : qsTr("This branch is %n commits behind its base.", "", root.detail.behindBy ?? 0)
                        color: root.warningColor
                        font.pixelSize: Theme.type.meta.size
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: root.detail.mergeability === "conflicting"
                        text: qsTr("This branch has conflicts with its base.")
                        color: root.errorColor
                        font.pixelSize: Theme.type.meta.size
                    }
                    Text {
                        objectName: "reviewDescription"
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        textFormat: Text.MarkdownText
                        text: (root.detail.body ?? "").length > 0 ? root.detail.body : qsTr("No description provided.")
                        color: (root.detail.body ?? "").length > 0 ? root.foreground : root.muted
                        font.pixelSize: Theme.type.body.size
                        linkColor: Theme.link
                        onLinkActivated: link => Qt.openUrlExternally(link)
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: (root.detail.labels ?? []).length > 0
                        wrapMode: Text.Wrap
                        text: qsTr("Labels: %1").arg((root.detail.labels ?? []).join(", "))
                        color: root.muted
                        font.pixelSize: Theme.type.meta.size
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: (root.detail.reviewers ?? []).length > 0
                        wrapMode: Text.Wrap
                        text: qsTr("Reviewers: %1").arg((root.detail.reviewers ?? []).join(", "))
                        color: root.muted
                        font.pixelSize: Theme.type.meta.size
                    }
                    Text {
                        Layout.topMargin: Theme.space.sm
                        text: qsTr("Checks")
                        color: root.foreground
                        font.pixelSize: Theme.type.meta.size
                        font.weight: Font.Medium
                    }
                    Text {
                        visible: (root.detail.checks ?? []).length === 0
                        text: qsTr("No checks reported.")
                        color: root.muted
                        font.pixelSize: Theme.type.meta.size
                    }
                    Repeater {
                        model: root.detail.checks ?? []

                        delegate: RowLayout {
                            required property var modelData

                            objectName: "reviewCheck-" + modelData.name
                            Layout.fillWidth: true
                            spacing: Theme.space.sm

                            Rectangle {
                                implicitWidth: 8
                                implicitHeight: 8
                                radius: Theme.radiusPill
                                color: root.checkColor(parent.modelData.status)
                            }
                            Text {
                                Layout.fillWidth: true
                                text: parent.modelData.name
                                elide: Text.ElideRight
                                color: root.foreground
                                font.pixelSize: Theme.type.meta.size
                            }
                            Text {
                                text: parent.modelData.status
                                color: root.checkColor(parent.modelData.status)
                                font.pixelSize: Theme.type.caption.size
                            }
                        }
                    }
                }
            }

            // The conversation, review threads, and what the user says back.
            ColumnLayout {
                anchors.fill: parent
                visible: root.section === "conversation" && root.source?.status === "ready"
                spacing: 0

                ListView {
                    id: conversation

                    objectName: "reviewConversation"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 8
                    topMargin: 8
                    bottomMargin: 8
                    boundsBehavior: Flickable.StopAtBounds
                    model: root.source?.conversation ?? []
                    header: Column {
                        width: conversation.width
                        spacing: Theme.space.sm

                        Repeater {
                            model: root.source?.reviewThreads ?? []

                            delegate: Rectangle {
                                id: reviewThread

                                required property var modelData

                                objectName: "reviewThread-" + modelData.id
                                x: 12
                                width: parent.width - 24
                                height: threadColumn.implicitHeight + 16
                                radius: Theme.radiusSm
                                color: "transparent"
                                border.color: root.borderColor

                                ColumnLayout {
                                    id: threadColumn

                                    x: 8
                                    y: 8
                                    width: parent.width - 16
                                    spacing: 4

                                    RowLayout {
                                        Layout.fillWidth: true

                                        Text {
                                            Layout.fillWidth: true
                                            text: reviewThread.modelData.path + (reviewThread.modelData.line > 0 ? ":" + reviewThread.modelData.line : "") + (reviewThread.modelData.outdated ? qsTr(" · outdated") : "") + (reviewThread.modelData.resolved ? qsTr(" · resolved") : "")
                                            elide: Text.ElideMiddle
                                            color: root.muted
                                            font.pixelSize: Theme.type.caption.size
                                        }
                                        ShellButton {
                                            objectName: "reviewThreadResolve"
                                            subtle: true
                                            text: reviewThread.modelData.resolved ? qsTr("Unresolve") : qsTr("Resolve")
                                            enabled: root.online && !root.source.busy
                                            onClicked: root.source.setThreadResolved(reviewThread.modelData.id, !reviewThread.modelData.resolved)
                                        }
                                    }
                                    Repeater {
                                        model: reviewThread.modelData.resolved ? [] : reviewThread.modelData.comments

                                        delegate: Text {
                                            required property var modelData

                                            Layout.fillWidth: true
                                            wrapMode: Text.Wrap
                                            text: "<b>" + modelData.author + "</b> " + modelData.body
                                            textFormat: Text.StyledText
                                            color: root.foreground
                                            font.pixelSize: Theme.type.meta.size
                                        }
                                    }
                                }
                            }
                        }
                    }

                    delegate: ColumnLayout {
                        id: comment

                        required property var modelData

                        x: 12
                        width: ListView.view.width - 24
                        spacing: 2

                        Text {
                            Layout.fillWidth: true
                            text: [comment.modelData.author, comment.modelData.reviewState.length > 0 ? comment.modelData.reviewState.toLowerCase().replace("_", " ") : "", comment.modelData.path].filter(part => part.length > 0).join(" · ")
                            elide: Text.ElideRight
                            color: root.muted
                            font.pixelSize: Theme.type.caption.size
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: comment.modelData.body.length > 0
                            wrapMode: Text.Wrap
                            textFormat: Text.MarkdownText
                            text: comment.modelData.body
                            color: root.foreground
                            font.pixelSize: Theme.type.meta.size
                            linkColor: Theme.link
                            onLinkActivated: link => Qt.openUrlExternally(link)
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: root.borderColor
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.margins: 8
                    spacing: Theme.space.sm

                    TextArea {
                        id: reply

                        objectName: "reviewReply"
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(Math.max(implicitHeight, 56), 160)
                        enabled: root.online
                        wrapMode: TextEdit.Wrap
                        placeholderText: qsTr("Leave a comment")
                        placeholderTextColor: root.muted
                        color: root.foreground
                        font.pixelSize: Theme.type.meta.size
                        background: Rectangle {
                            radius: Theme.radiusSm
                            color: "transparent"
                            border.color: reply.activeFocus ? Theme.palette.color("focus", "#3b82f6") : root.borderColor
                        }
                    }
                    Text {
                        objectName: "reviewProblem"
                        Layout.fillWidth: true
                        visible: text.length > 0
                        wrapMode: Text.Wrap
                        text: root.source?.problem ?? ""
                        color: root.errorColor
                        font.pixelSize: Theme.type.meta.size
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.space.sm

                        Item {
                            Layout.fillWidth: true
                        }
                        ShellButton {
                            objectName: "reviewSubmit"
                            text: qsTr("Review")
                            chevron: true
                            enabled: root.online && !root.source.busy
                            onClicked: verdicts.open()

                            ShellMenu {
                                id: verdicts

                                y: -implicitHeight

                                ShellMenuItem {
                                    text: qsTr("Comment")
                                    iconName: "message-square"
                                    onTriggered: if (root.source.submitReview("comment", reply.text))
                                        reply.clear()
                                }
                                ShellMenuItem {
                                    text: qsTr("Approve")
                                    iconName: "circle-check"
                                    onTriggered: if (root.source.submitReview("approve", reply.text))
                                        reply.clear()
                                }
                                ShellMenuItem {
                                    text: qsTr("Request changes")
                                    iconName: "circle-x"
                                    onTriggered: if (root.source.submitReview("request-changes", reply.text))
                                        reply.clear()
                                }
                            }
                        }
                        ShellButton {
                            objectName: "reviewComment"
                            primary: true
                            text: qsTr("Comment")
                            enabled: root.online && !root.source.busy && reply.text.trim().length > 0
                            onClicked: if (root.source.comment(reply.text))
                                reply.clear()
                        }
                    }
                }
            }

            DiffPanel {
                objectName: "reviewCode"
                anchors.fill: parent
                visible: root.section === "code"
                source: code
            }
        }
    }

    // A stack action says what it will do before it does it.
    Dialog {
        id: stackConfirm

        readonly property var question: root.source?.stackConfirmation ?? ({})
        readonly property bool asked: (question.action ?? "").length > 0

        objectName: "reviewStackConfirm"
        parent: Overlay.overlay
        modal: true
        anchors.centerIn: parent
        scale: Shell.state.layout?.zoom ?? 1
        transformOrigin: Item.TopLeft
        width: Math.min(440, (parent?.width ?? 472) / scale - 32)
        padding: 20
        closePolicy: Popup.CloseOnEscape
        onAskedChanged: asked ? open() : close()
        onRejected: root.source.cancelStack()

        Overlay.modal: ShellScrim {}
        background: ShellPopoverSurface {}
        contentItem: ColumnLayout {
            spacing: 12

            Label {
                objectName: "reviewStackConfirmTitle"
                Layout.fillWidth: true
                text: stackConfirm.question.title ?? ""
                color: root.foreground
                font.pixelSize: Theme.type.title.size
                font.weight: Font.DemiBold
                wrapMode: Text.Wrap
            }
            Label {
                objectName: "reviewStackConfirmDescription"
                Layout.fillWidth: true
                text: stackConfirm.question.description ?? ""
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Theme.type.body.size
                wrapMode: Text.Wrap
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Item {
                    Layout.fillWidth: true
                }
                ShellButton {
                    objectName: "reviewStackConfirmCancel"
                    text: qsTr("Cancel")
                    onClicked: stackConfirm.reject()
                }
                ShellButton {
                    objectName: "reviewStackConfirmAccept"
                    primary: true
                    text: stackConfirm.question.confirmLabel ?? qsTr("Confirm")
                    onClicked: root.source.confirmStack()
                }
            }
        }
    }

    // The thread picker: the environment's active threads, newest first; one
    // that already links the pull request shows "Linked" and cannot be chosen.
    Dialog {
        id: threadPicker

        objectName: "reviewThreadPicker"
        parent: Overlay.overlay
        modal: true
        anchors.centerIn: parent
        width: Math.min(420, (parent?.width ?? 452) - 32)
        padding: 8
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        visible: root.threads?.pickerOpen ?? false
        onClosed: if (root.threads)
            root.threads.pickerOpen = false
        onOpened: threadSearch.forceActiveFocus()

        Overlay.modal: ShellScrim {}
        background: ShellPopoverSurface {}
        contentItem: ColumnLayout {
            spacing: Theme.space.sm

            ShellTextField {
                id: threadSearch

                objectName: "reviewThreadSearch"
                Layout.fillWidth: true
                placeholderText: qsTr("Search threads or projects...")
                text: root.threads?.query ?? ""
                enabled: !(root.threads?.pending ?? false)
                onTextEdited: root.threads.query = text
            }
            Text {
                objectName: "reviewThreadPickerEmpty"
                Layout.fillWidth: true
                Layout.topMargin: 16
                Layout.bottomMargin: 16
                visible: threadList.count === 0
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("No active threads found.")
                color: root.muted
                font.pixelSize: Theme.type.meta.size
            }
            ListView {
                id: threadList

                objectName: "reviewThreadList"
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(contentHeight, 320)
                visible: count > 0
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: root.threads?.candidates ?? []

                delegate: ItemDelegate {
                    id: candidate

                    required property var modelData

                    objectName: "reviewThreadCandidate-" + modelData.id
                    width: ListView.view.width
                    enabled: !modelData.linked && !(root.threads?.pending ?? false)
                    onClicked: root.threads.choose(modelData.id)

                    background: Rectangle {
                        color: candidate.hovered && candidate.enabled ? Theme.palette.color("accentSurface", "#27272a") : "transparent"
                        radius: Theme.radiusSm
                    }
                    contentItem: RowLayout {
                        spacing: 8

                        ShellIcon {
                            name: "message-square"
                            size: 14
                            color: root.muted
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            Text {
                                Layout.fillWidth: true
                                text: candidate.modelData.title
                                elide: Text.ElideRight
                                color: candidate.enabled ? root.foreground : root.muted
                                font.pixelSize: Theme.type.body.size
                            }
                            Text {
                                Layout.fillWidth: true
                                visible: text.length > 0
                                text: candidate.modelData.project
                                elide: Text.ElideRight
                                color: root.muted
                                font.pixelSize: Theme.type.caption.size
                            }
                        }
                        ShellIcon {
                            visible: candidate.modelData.linked
                            name: "check"
                            size: 12
                            color: root.muted
                        }
                        Text {
                            visible: candidate.modelData.linked
                            text: qsTr("Linked")
                            color: root.muted
                            font.pixelSize: Theme.type.caption.size
                        }
                    }
                }
            }
        }
    }
}
