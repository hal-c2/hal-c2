import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell

// The right panel's Pull requests tab: the pull requests linked to the thread
// with their state, checks and review, from a ThreadPullRequests model
// (Panel.pullRequests). A row opens in the browser; its menu opens its review
// tab, copies the link or unlinks it. The header links one (a URL or #123) and refreshes them all.
// Offline, the rows stay as last synced and nothing is offered.
//
//   PullRequestsPanel { anchors.fill: parent; source: Panel.pullRequests }
Rectangle {
    id: root

    property var source: null

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
    readonly property color successColor: Theme.palette.color("success", "#22c55e")
    readonly property color warningColor: Theme.palette.color("warning", "#f59e0b")
    readonly property color infoColor: Theme.palette.color("info", "#38bdf8")
    readonly property bool online: source !== null && source.online

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
            text: root.source && root.source.count > 0 ? qsTr("%1 open · %2 linked").arg(root.source.openCount).arg(root.source.count) : qsTr("Pull requests")
            elide: Text.ElideRight
            color: root.muted
            font.pixelSize: 12
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
                visible: root.source !== null && root.source.count > 0
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
        spacing: 6

        Text {
            objectName: "pullRequestsOffline"
            x: 12
            width: parent.width - 24
            visible: root.source !== null && !root.online
            wrapMode: Text.Wrap
            text: qsTr("This environment is unreachable. Pull requests show as last synced.")
            color: root.warningColor
            font.pixelSize: 12
        }

        Item {
            x: 12
            width: parent.width - 24
            height: linkField.height
            visible: root.source !== null && root.source.linkOpen && root.online

            ShellTextField {
                id: linkField

                objectName: "pullRequestsLinkField"
                anchors.left: parent.left
                anchors.right: linkButton.left
                anchors.rightMargin: 6
                placeholderText: qsTr("Pull request URL or #123")
                enabled: !root.source || !root.source.linking
                onVisibleChanged: {
                    if (visible) {
                        text = "";
                        forceActiveFocus();
                    }
                }
                onAccepted: root.source.link(text)
                Keys.onEscapePressed: root.source.linkOpen = false
            }

            ShellButton {
                id: linkButton

                anchors.right: parent.right
                primary: true
                text: qsTr("Link")
                enabled: linkField.text.trim().length > 0 && root.source && !root.source.linking
                onClicked: root.source.link(linkField.text)
            }
        }

        Text {
            objectName: "pullRequestsProblem"
            x: 12
            width: parent.width - 24
            visible: text.length > 0
            wrapMode: Text.Wrap
            text: root.source ? root.source.problem : ""
            color: root.errorColor
            font.pixelSize: 12
        }
    }

    Column {
        objectName: "pullRequestsEmpty"
        anchors.centerIn: parent
        width: parent.width - 32
        spacing: 8
        visible: list.count === 0

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("No linked pull requests")
            color: root.foreground
            font.pixelSize: 13
            font.weight: Font.Medium
        }
        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: qsTr("Pull requests the agent opens from this thread land here. Link one yourself from a URL or a number.")
            color: root.muted
            font.pixelSize: 12
        }
    }

    ListView {
        id: list

        objectName: "pullRequestsList"
        anchors.top: top.bottom
        anchors.topMargin: 4
        anchors.bottom: parent.bottom
        width: parent.width
        leftMargin: 6
        rightMargin: 6
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.source

        delegate: AbstractButton {
            id: row

            required property string linkKey
            required property string repository
            required property int number
            required property string title
            required property string state
            required property string stateLabel
            required property string checks
            required property string checksLabel
            required property string review
            required property string reviewLabel
            required property bool conflicting
            required property string branches
            required property string sourceLabel
            required property string unlinkLabel

            objectName: "pullRequestRow-" + number
            width: ListView.view.width - 12
            height: 62
            hoverEnabled: true
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("%1 #%2, %3").arg(row.repository).arg(row.number).arg(row.stateLabel)
            onClicked: root.source.open(row.linkKey)
            background: Rectangle {
                radius: 6
                color: row.hovered || row.visualFocus ? Theme.palette.color("surfaceRaised", "#1f1f24") : "transparent"
            }

            ShellIcon {
                id: glyph

                x: 8
                y: 8
                size: 14
                name: root.stateIcon(row.state)
                color: root.stateColor(row.state)
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
                font.pixelSize: 13
                font.weight: Font.Medium
            }

            Text {
                anchors.left: titleText.left
                anchors.right: menuButton.left
                anchors.rightMargin: 4
                y: 25
                text: [qsTr("%1 #%2").arg(row.repository).arg(row.number), row.branches].filter(part => part.length > 0).join(" · ")
                elide: Text.ElideRight
                maximumLineCount: 1
                color: root.muted
                font.pixelSize: 11
            }

            Row {
                anchors.left: titleText.left
                y: 42
                spacing: 8

                Text {
                    objectName: "pullRequestState"
                    text: row.stateLabel
                    color: root.stateColor(row.state)
                    font.pixelSize: 11
                }
                Text {
                    objectName: "pullRequestChecks"
                    visible: text.length > 0
                    text: row.checksLabel
                    color: root.checksColor(row.checks)
                    font.pixelSize: 11
                }
                Text {
                    objectName: "pullRequestReview"
                    visible: text.length > 0
                    text: row.reviewLabel
                    color: root.reviewColor(row.review)
                    font.pixelSize: 11
                }
                Text {
                    visible: row.conflicting
                    text: qsTr("Conflicts")
                    color: root.errorColor
                    font.pixelSize: 11
                }
                Text {
                    text: row.sourceLabel
                    color: root.muted
                    font.pixelSize: 11
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
                Accessible.name: qsTr("Pull request actions")
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
                        text: qsTr("Open in browser")
                        iconName: "external-link"
                        onTriggered: root.source.open(row.linkKey)
                    }
                    ShellMenuItem {
                        text: qsTr("Copy link")
                        iconName: "copy"
                        onTriggered: root.source.copyLink(row.linkKey)
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
