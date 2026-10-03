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
    readonly property bool online: source !== null && source.online
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color border: Theme.palette.color("border", "#27272a")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
    readonly property color successColor: Theme.palette.color("success", "#22c55e")
    readonly property color warningColor: Theme.palette.color("warning", "#f59e0b")

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
            spacing: 6

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
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                    font.weight: Font.Medium
                }
                Text {
                    Layout.fillWidth: true
                    text: ["#" + (root.source?.number ?? 0), root.detail.stateLabel ?? "", root.detail.author ?? "", root.detail.branches ?? ""].filter(part => part.length > 0).join(" · ")
                    elide: Text.ElideRight
                    color: root.muted
                    font.pixelSize: Math.round(11 * Theme.fontScale)
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
            Layout.bottomMargin: 6
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
            Layout.bottomMargin: 6
            visible: root.source !== null && !root.online
            wrapMode: Text.Wrap
            text: qsTr("This environment is unreachable. The pull request shows as last read.")
            color: root.warningColor
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: root.border
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            ColumnLayout {
                objectName: "reviewMessage"
                anchors.centerIn: parent
                width: parent.width - 32
                visible: root.section !== "code" && (root.source?.status ?? "idle") !== "ready"
                spacing: 10

                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    text: root.source?.status === "error" ? root.source.message : root.source?.status === "loading" ? qsTr("Loading the pull request…") : ""
                    color: root.source?.status === "error" ? root.errorColor : root.muted
                    font.pixelSize: Math.round(13 * Theme.fontScale)
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
                    spacing: 10

                    Text {
                        Layout.fillWidth: true
                        visible: (root.detail.behindBy ?? 0) > 0
                        wrapMode: Text.Wrap
                        text: qsTr("This branch is %n commit(s) behind its base.", "", root.detail.behindBy ?? 0)
                        color: root.warningColor
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: root.detail.mergeability === "conflicting"
                        text: qsTr("This branch has conflicts with its base.")
                        color: root.errorColor
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }
                    Text {
                        objectName: "reviewDescription"
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        textFormat: Text.MarkdownText
                        text: (root.detail.body ?? "").length > 0 ? root.detail.body : qsTr("No description provided.")
                        color: (root.detail.body ?? "").length > 0 ? root.foreground : root.muted
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                        linkColor: Theme.link
                        onLinkActivated: link => Qt.openUrlExternally(link)
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: (root.detail.labels ?? []).length > 0
                        wrapMode: Text.Wrap
                        text: qsTr("Labels: %1").arg((root.detail.labels ?? []).join(", "))
                        color: root.muted
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: (root.detail.reviewers ?? []).length > 0
                        wrapMode: Text.Wrap
                        text: qsTr("Reviewers: %1").arg((root.detail.reviewers ?? []).join(", "))
                        color: root.muted
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }
                    Text {
                        Layout.topMargin: 6
                        text: qsTr("Checks")
                        color: root.foreground
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        font.weight: Font.Medium
                    }
                    Text {
                        visible: (root.detail.checks ?? []).length === 0
                        text: qsTr("No checks reported.")
                        color: root.muted
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }
                    Repeater {
                        model: root.detail.checks ?? []

                        delegate: RowLayout {
                            required property var modelData

                            objectName: "reviewCheck-" + modelData.name
                            Layout.fillWidth: true
                            spacing: 6

                            Rectangle {
                                implicitWidth: 8
                                implicitHeight: 8
                                radius: 4
                                color: root.checkColor(parent.modelData.status)
                            }
                            Text {
                                Layout.fillWidth: true
                                text: parent.modelData.name
                                elide: Text.ElideRight
                                color: root.foreground
                                font.pixelSize: Math.round(12 * Theme.fontScale)
                            }
                            Text {
                                text: parent.modelData.status
                                color: root.checkColor(parent.modelData.status)
                                font.pixelSize: Math.round(11 * Theme.fontScale)
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
                        spacing: 6

                        Repeater {
                            model: root.source?.reviewThreads ?? []

                            delegate: Rectangle {
                                required property var modelData

                                objectName: "reviewThread-" + modelData.id
                                x: 12
                                width: parent.width - 24
                                height: threadColumn.implicitHeight + 16
                                radius: 6
                                color: "transparent"
                                border.color: root.border

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
                                            text: modelData.path + (modelData.line > 0 ? ":" + modelData.line : "") + (modelData.outdated ? qsTr(" · outdated") : "") + (modelData.resolved ? qsTr(" · resolved") : "")
                                            elide: Text.ElideMiddle
                                            color: root.muted
                                            font.pixelSize: Math.round(11 * Theme.fontScale)
                                        }
                                        ShellButton {
                                            objectName: "reviewThreadResolve"
                                            subtle: true
                                            text: modelData.resolved ? qsTr("Unresolve") : qsTr("Resolve")
                                            enabled: root.online && !root.source.busy
                                            onClicked: root.source.setThreadResolved(modelData.id, !modelData.resolved)
                                        }
                                    }
                                    Repeater {
                                        model: modelData.resolved ? [] : modelData.comments

                                        delegate: Text {
                                            required property var modelData

                                            Layout.fillWidth: true
                                            wrapMode: Text.Wrap
                                            text: "<b>" + modelData.author + "</b> " + modelData.body
                                            textFormat: Text.StyledText
                                            color: root.foreground
                                            font.pixelSize: Math.round(12 * Theme.fontScale)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    delegate: ColumnLayout {
                        required property var modelData

                        x: 12
                        width: ListView.view.width - 24
                        spacing: 2

                        Text {
                            Layout.fillWidth: true
                            text: [modelData.author, modelData.reviewState.length > 0 ? modelData.reviewState.toLowerCase().replace("_", " ") : "", modelData.path].filter(part => part.length > 0).join(" · ")
                            elide: Text.ElideRight
                            color: root.muted
                            font.pixelSize: Math.round(11 * Theme.fontScale)
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: modelData.body.length > 0
                            wrapMode: Text.Wrap
                            textFormat: Text.MarkdownText
                            text: modelData.body
                            color: root.foreground
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            linkColor: Theme.link
                            onLinkActivated: link => Qt.openUrlExternally(link)
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: root.border
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.margins: 8
                    spacing: 6

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
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        background: Rectangle {
                            radius: 6
                            color: "transparent"
                            border.color: reply.activeFocus ? Theme.palette.color("focus", "#3b82f6") : root.border
                        }
                    }
                    Text {
                        objectName: "reviewProblem"
                        Layout.fillWidth: true
                        visible: text.length > 0
                        wrapMode: Text.Wrap
                        text: root.source?.problem ?? ""
                        color: root.errorColor
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

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
}
