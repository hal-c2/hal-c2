pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell

// The right panel's Pull requests tab: the pull requests linked to the thread
// with their state, checks and review, from a ThreadPullRequests model
// (Panel.pullRequests), stacks stepped in bottom to top. A row opens in the
// browser; its menu opens its review tab, copies the link, opens it or unlinks
// it (a stack layer is dismissed). The header links one (a URL or #123) and
// refreshes them all. Offline, the rows stay as last synced and nothing is
// offered; an environment without linked pull requests says so instead.
//
//   PullRequestsPanel { anchors.fill: parent; source: Panel.pullRequests }
Rectangle {
    id: root

    property var source: null

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color errorColor: Theme.palette.color("errorForeground", "#ef4444")
    readonly property color successColor: Theme.palette.color("success", "#22c55e")
    readonly property color warningColor: Theme.palette.color("warningForeground", "#f59e0b")
    readonly property color infoColor: Theme.palette.color("info", "#38bdf8")
    readonly property bool online: source !== null && source.online
    // The project's other open pull requests, under the linked ones.
    readonly property var projectOpen: source?.projectOpen ?? []
    // Stack layers dismissed from the thread, each of which can be linked again.
    readonly property var dismissed: source?.dismissed ?? []
    readonly property bool available: source === null || source.available !== false

    onVisibleChanged: if (visible && source && typeof source.loadProject === "function")
        source.loadProject()
    Component.onCompleted: if (visible && source && typeof source.loadProject === "function")
        source.loadProject()

    function stateIcon(state) {
        if (state === "merged")
            return "git-merge";
        if (state === "closed")
            return "circle-x";
        if (state === "unknown")
            return "circle-dashed";
        return "git-pull-request";
    }
    function stateColor(state) {
        if (state === "open")
            return root.successColor;
        if (state === "merged")
            return Theme.palette.color("merged", "#a855f7");
        if (state === "closed")
            return root.errorColor;
        return root.muted;
    }
    function checksColor(checks) {
        return checks === "passing" ? root.successColor : checks === "failing" ? root.errorColor : root.warningColor;
    }
    function reviewColor(review) {
        return review === "approved" ? root.successColor : review === "changes-requested" ? root.errorColor : root.muted;
    }

    objectName: "pullRequestsPanel"
    color: Theme.palette.color("surface", "#0f0f11")

    Item {
        id: header

        width: parent.width
        height: 40

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.right: actions.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.source && root.source.count > 0 ? [qsTr("%1 open · %2 linked").arg(root.source.openCount).arg(root.source.count), root.source.syncedLabel ?? ""].filter(part => part.length > 0).join(" · ") : qsTr("Pull requests")
            elide: Text.ElideRight
            color: root.muted
            font.pixelSize: Theme.type.meta.size
        }

        Row {
            id: actions

            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            ShellButton {
                objectName: "pullRequestsRefresh"
                subtle: true
                iconName: "refresh-cw"
                visible: root.source !== null && root.source.count > 0 && root.available
                enabled: root.online && !root.source.refreshing
                Accessible.name: qsTr("Refresh pull requests")
                ToolTip.visible: hovered
                ToolTip.text: Accessible.name
                onClicked: root.source.refresh()
            }

            ShellButton {
                objectName: "pullRequestsLink"
                subtle: true
                iconName: "plus"
                visible: root.available
                enabled: root.online
                checked: root.source !== null && root.source.linkOpen
                Accessible.name: qsTr("Link pull request")
                ToolTip.visible: hovered
                ToolTip.text: Accessible.name
                onClicked: root.source.linkOpen = !root.source.linkOpen
            }
        }
    }

    Column {
        id: top

        anchors.top: header.bottom
        width: parent.width
        spacing: Theme.space.sm

        Text {
            objectName: "pullRequestsOffline"
            x: 12
            width: parent.width - 24
            visible: root.source !== null && !root.online
            wrapMode: Text.Wrap
            text: qsTr("This environment is unreachable. Pull requests show as last synced.")
            color: root.warningColor
            font.pixelSize: Theme.type.meta.size
        }

        // LinkPullRequestDialog, in place: what the reference links, or why it cannot.
        Item {
            x: 12
            width: parent.width - 24
            height: linkField.height
            visible: root.source !== null && root.source.linkOpen && root.online && root.available

            ShellTextField {
                id: linkField

                objectName: "pullRequestsLinkField"
                anchors.left: parent.left
                anchors.right: linkButton.left
                anchors.rightMargin: Theme.space.sm
                placeholderText: qsTr("Pull request URL or #123")
                text: root.source?.reference ?? ""
                enabled: !root.source || !root.source.linking
                onVisibleChanged: {
                    if (visible)
                        forceActiveFocus();
                }
                onTextEdited: if (root.source && "reference" in root.source)
                    root.source.reference = text
                onAccepted: root.source.link(text)
                Keys.onEscapePressed: if (!root.source.linking)
                    root.source.linkOpen = false
            }

            ShellButton {
                id: linkButton

                objectName: "pullRequestsLinkSubmit"
                anchors.right: parent.right
                primary: true
                text: root.source && root.source.linking ? qsTr("Linking...") : qsTr("Link")
                enabled: root.source !== null && !root.source.linking && (root.source.canLink ?? linkField.text.trim().length > 0)
                onClicked: root.source.link(linkField.text)
            }
        }

        Text {
            objectName: "pullRequestsLinkPreview"
            x: 12
            width: parent.width - 24
            visible: root.source !== null && root.source.linkOpen && text.length > 0 && (root.source.problem ?? "").length === 0
            elide: Text.ElideMiddle
            text: root.source?.preview ?? ""
            color: root.muted
            font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
            font.pixelSize: Theme.type.caption.size
        }

        Text {
            objectName: "pullRequestsNotice"
            x: 12
            width: parent.width - 24
            visible: text.length > 0
            wrapMode: Text.Wrap
            text: root.source?.notice ?? ""
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Theme.type.meta.size
        }

        Text {
            objectName: "pullRequestsProblem"
            x: 12
            width: parent.width - 24
            visible: text.length > 0
            wrapMode: Text.Wrap
            text: root.source ? root.source.problem : ""
            color: root.errorColor
            font.pixelSize: Theme.type.meta.size
        }
    }

    // PullRequestsUnavailableState: an environment that keeps one pull request per thread.
    Column {
        objectName: "pullRequestsUnavailable"
        anchors.centerIn: parent
        width: parent.width - 32
        spacing: 8
        visible: !root.available

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("Linked pull requests unavailable")
            color: root.foreground
            font.pixelSize: Theme.type.body.size
            font.weight: Font.Medium
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: qsTr("This environment does not support multiple linked pull requests.")
            color: root.muted
            font.pixelSize: Theme.type.meta.size
        }
    }

    Column {
        objectName: "pullRequestsEmpty"
        anchors.centerIn: parent
        width: parent.width - 32
        spacing: 8
        // Above the empty list, which would take its button's clicks.
        z: 1
        visible: root.available && list.count === 0 && root.projectOpen.length === 0 && root.dismissed.length === 0

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("No linked pull requests")
            color: root.foreground
            font.pixelSize: Theme.type.body.size
            font.weight: Font.Medium
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: qsTr("Pull requests the agent opens from this thread land here. Link one yourself from a URL or a number.")
            color: root.muted
            font.pixelSize: Theme.type.meta.size
        }
        ShellButton {
            objectName: "pullRequestsEmptyLink"
            anchors.horizontalCenter: parent.horizontalCenter
            iconName: "plus"
            text: qsTr("Link pull request")
            visible: !(root.source?.linkOpen ?? false)
            enabled: root.online
            onClicked: root.source.linkOpen = true
        }
    }

    ListView {
        id: list

        objectName: "pullRequestsList"
        anchors.top: top.bottom
        anchors.topMargin: 4
        anchors.bottom: parent.bottom
        width: parent.width
        leftMargin: Theme.space.sm
        rightMargin: Theme.space.sm
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        visible: root.available
        model: root.source

        // The stack layers dismissed from the thread, then the open pull
        // requests of the thread's project: each opens its review.
        footer: Column {
            width: list.width - 12
            visible: root.dismissed.length > 0 || root.projectOpen.length > 0 || (root.source?.projectProblem ?? "").length > 0
            height: visible ? implicitHeight : 0
            topPadding: Theme.space.sm

            Repeater {
                model: root.dismissed

                delegate: Item {
                    id: dismissedRow

                    required property var modelData

                    objectName: "dismissedPullRequest-" + modelData.number
                    width: parent.width
                    height: 30

                    Text {
                        x: 8
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - x - relinkButton.width - 12
                        text: [qsTr("#%1").arg(dismissedRow.modelData.number), dismissedRow.modelData.title.length > 0 ? dismissedRow.modelData.title : dismissedRow.modelData.repository, dismissedRow.modelData.sourceLabel].join(" · ")
                        color: root.muted
                        font.pixelSize: Theme.type.caption.size
                        elide: Text.ElideRight
                    }
                    ShellButton {
                        id: relinkButton

                        objectName: "dismissedPullRequestLink-" + dismissedRow.modelData.number
                        anchors.right: parent.right
                        anchors.rightMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        implicitHeight: 24
                        subtle: true
                        text: qsTr("Link again")
                        enabled: root.online
                        onClicked: root.source.link(dismissedRow.modelData.url)
                    }
                }
            }

            Text {
                objectName: "projectPullRequestsTitle"
                visible: root.projectOpen.length > 0 || (root.source?.projectProblem ?? "").length > 0
                x: 8
                height: 24
                verticalAlignment: Text.AlignVCenter
                text: qsTr("Open in this project")
                color: root.muted
                font.pixelSize: Theme.type.caption.size
                font.weight: Font.Medium
            }
            Text {
                x: 8
                width: parent.width - 16
                visible: text.length > 0
                text: root.source?.projectProblem ?? ""
                color: root.errorColor
                font.pixelSize: Theme.type.meta.size
                wrapMode: Text.Wrap
            }
            Repeater {
                model: root.projectOpen

                delegate: AbstractButton {
                    // Not `open`: RightPanel, an ancestor, has an `open` property.
                    id: projectRow

                    required property var modelData

                    objectName: "projectPullRequest-" + modelData.number
                    width: parent.width
                    height: 44
                    Accessible.name: qsTr("Review #%1 %2").arg(modelData.number).arg(modelData.title)
                    onClicked: Shell.dispatch("rightPanel.reviewProject", {
                        key: projectRow.modelData.key
                    })
                    background: Rectangle {
                        radius: Theme.radiusSm
                        color: projectRow.hovered ? Theme.palette.color("surfaceRaised", "#1f1f24") : "transparent"
                    }
                    contentItem: Item {
                        ShellIcon {
                            x: 8
                            y: 8
                            name: "git-pull-request"
                            size: 14
                            color: projectRow.modelData.draft ? root.muted : root.successColor
                        }
                        Text {
                            x: 30
                            y: 5
                            width: parent.width - x - openLinkButton.width - 12
                            text: projectRow.modelData.title
                            color: root.foreground
                            font.pixelSize: Theme.type.body.size
                            elide: Text.ElideRight
                        }
                        Text {
                            x: 30
                            y: 24
                            width: parent.width - x - openLinkButton.width - 12
                            text: [qsTr("#%1").arg(projectRow.modelData.number), projectRow.modelData.author, projectRow.modelData.branches].filter(part => part.length > 0).join(" · ")
                            color: root.muted
                            font.pixelSize: Theme.type.caption.size
                            elide: Text.ElideRight
                        }
                        ShellButton {
                            id: openLinkButton

                            objectName: "projectPullRequestLink-" + projectRow.modelData.number
                            anchors.right: parent.right
                            anchors.rightMargin: 4
                            anchors.verticalCenter: parent.verticalCenter
                            implicitHeight: 24
                            subtle: true
                            text: qsTr("Link")
                            enabled: root.online
                            onClicked: root.source.link(projectRow.modelData.url)
                        }
                    }
                }
            }
        }

        delegate: AbstractButton {
            id: row

            required property string linkKey
            required property string repository
            required property int number
            required property string title
            required property string stateLabel
            required property string checks
            required property string checksLabel
            required property string review
            required property string reviewLabel
            required property bool conflicting
            required property string branches
            required property string sourceLabel
            // A role a model may leave out (stackLabel), and `state`, which as a
            // required property would shadow Item.state.
            required property var model
            required property string unlinkLabel
            required property string host
            required property string linkedNote
            required property int depth
            required property int stackSize
            required property string stackNote
            // Each layer steps in under the one it targets, a few steps at most.
            readonly property real indent: Math.min(depth, 3) * 16

            objectName: "pullRequestRow-" + number
            width: ListView.view.width - 12
            height: 62
            hoverEnabled: true
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("%1 #%2, %3").arg(row.repository).arg(row.number).arg(row.stateLabel)
            onClicked: root.source.open(row.linkKey)
            background: Rectangle {
                radius: Theme.radiusSm
                color: row.hovered || row.visualFocus ? Theme.palette.color("surfaceRaised", "#1f1f24") : "transparent"
            }

            Rectangle {
                visible: row.depth > 0
                x: row.indent
                y: 6
                width: 1
                height: 24
                color: Theme.palette.color("border", "#2a2a30")
            }

            ShellIcon {
                id: glyph

                x: 8 + row.indent
                y: 8
                size: 14
                name: root.stateIcon(row.model.state)
                color: root.stateColor(row.model.state)
                ToolTip.visible: glyphArea.containsMouse
                ToolTip.text: row.stateLabel

                MouseArea {
                    id: glyphArea

                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                }
            }

            Text {
                id: titleText

                anchors.left: glyph.right
                anchors.leftMargin: 8
                anchors.right: menuButton.left
                anchors.rightMargin: 4
                y: 6
                text: row.title.length > 0 ? row.title : qsTr("%1 #%2").arg(row.repository).arg(row.number)
                elide: Text.ElideRight
                maximumLineCount: 1
                color: root.foreground
                font.pixelSize: Theme.type.body.size
                font.weight: Font.Medium
            }

            // The number says how and when it was linked; the bottom of a stack
            // says what kind of stack it is; then the repository (the host's
            // too until the host was read) and the branches.
            Row {
                id: meta

                anchors.left: titleText.left
                anchors.right: menuButton.left
                anchors.rightMargin: 4
                y: 25
                spacing: Theme.space.sm

                Text {
                    id: numberText

                    objectName: "pullRequestNumber"
                    text: qsTr("#%1").arg(row.number)
                    color: root.foreground
                    font.pixelSize: Theme.type.caption.size
                    ToolTip.visible: numberArea.containsMouse
                    ToolTip.text: row.linkedNote

                    MouseArea {
                        id: numberArea

                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton
                    }
                    // The number's menu: copy its link, or open it on its host.
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        // ljos-allow(focus-pointer-only): the row's menu button offers the same from the keyboard
                        onTapped: eventPoint => Shell.dispatch("pullRequest.linkMenu", {
                                url: row.model.url ?? "",
                                x: eventPoint.scenePosition.x,
                                y: eventPoint.scenePosition.y
                            })
                    }
                }
                Row {
                    id: stackChip

                    objectName: "pullRequestStack"
                    visible: row.stackSize > 1
                    spacing: 2
                    ToolTip.visible: stackHover.hovered
                    ToolTip.text: row.stackNote

                    ShellIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "layers"
                        size: 11
                        color: root.muted
                    }
                    Text {
                        text: row.stackSize
                        color: root.muted
                        font.pixelSize: Theme.type.caption.size
                    }

                    // A handler, not a MouseArea: the Row would lay one out by its own width.
                    HoverHandler {
                        id: stackHover
                    }
                }
                Text {
                    objectName: "pullRequestRepository"
                    width: Math.min(implicitWidth, meta.width - numberText.width - (stackChip.visible ? stackChip.width + meta.spacing : 0) - meta.spacing)
                    text: [row.branches.length > 0 ? row.repository : row.host + "/" + row.repository, row.branches, row.model.stackLabel ?? ""].filter(part => part.length > 0).join(" · ")
                    elide: Text.ElideMiddle
                    maximumLineCount: 1
                    color: root.muted
                    font.pixelSize: Theme.type.caption.size
                    ToolTip.visible: repositoryArea.containsMouse && truncated
                    ToolTip.text: text

                    MouseArea {
                        id: repositoryArea

                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton
                    }
                }
            }

            Row {
                anchors.left: titleText.left
                y: 42
                spacing: 8

                Text {
                    objectName: "pullRequestState"
                    text: row.stateLabel
                    color: root.stateColor(row.model.state)
                    font.pixelSize: Theme.type.caption.size
                }
                Text {
                    objectName: "pullRequestChecks"
                    visible: text.length > 0
                    text: row.checksLabel
                    color: root.checksColor(row.checks)
                    font.pixelSize: Theme.type.caption.size
                }
                Text {
                    objectName: "pullRequestReview"
                    visible: text.length > 0
                    text: row.reviewLabel
                    color: root.reviewColor(row.review)
                    font.pixelSize: Theme.type.caption.size
                }
                Text {
                    visible: row.conflicting
                    text: qsTr("Conflicts")
                    color: root.errorColor
                    font.pixelSize: Theme.type.caption.size
                }
                Text {
                    text: row.sourceLabel
                    color: root.muted
                    font.pixelSize: Theme.type.caption.size
                }
            }

            ShellButton {
                id: menuButton

                objectName: "pullRequestMenu"
                anchors.right: parent.right
                anchors.rightMargin: 4
                y: 4
                subtle: true
                iconName: "ellipsis"
                Accessible.name: qsTr("Actions for #%1").arg(row.number)
                onClicked: rowMenu.open()

                ShellMenu {
                    id: rowMenu

                    y: parent.height

                    ShellMenuItem {
                        objectName: "pullRequestReviewItem"
                        text: qsTr("Review")
                        iconName: "git-pull-request"
                        onTriggered: Shell.dispatch("rightPanel.review", {
                            key: row.linkKey
                        })
                    }
                    ShellMenuItem {
                        objectName: "pullRequestCopyLink"
                        text: qsTr("Copy link")
                        iconName: "link"
                        onTriggered: root.source.copyLink(row.linkKey)
                    }
                    ShellMenuItem {
                        objectName: "pullRequestOpen"
                        text: qsTr("Open")
                        iconName: "external-link"
                        onTriggered: root.source.open(row.linkKey)
                    }
                    ShellMenuItem {
                        objectName: "pullRequestUnlink"
                        text: row.unlinkLabel
                        iconName: "link-less"
                        destructive: true
                        enabled: root.online
                        onTriggered: root.source.unlink(row.linkKey)
                    }
                }
            }
        }
    }
}
