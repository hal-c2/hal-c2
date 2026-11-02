pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// The open page's versions (Spaces.history) in a column beside it, newest
// first: each says when it was written and by whom, opens to be read, and all
// but the newest, which is the page as it is, can be restored.
Rectangle {
    id: panel

    objectName: "spaceHistoryPanel"

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color lineColor: Theme.palette.color("border", "#27272a")
    readonly property bool trashed: Spaces.page.trashed === true

    color: Theme.palette.color("surface", "#09090b")

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            // On the left: the toasts stack in the window's top right corner.
            ShellButton {
                objectName: "spaceHistoryClose"
                subtle: true
                iconName: "x"
                Accessible.name: qsTr("Hide history")
                onClicked: Shell.dispatch("space.history.close", {})
            }

            Text {
                Layout.fillWidth: true
                text: qsTr("History")
                color: panel.foreground
                font.pixelSize: Math.round(14 * Theme.fontScale)
                font.weight: Font.DemiBold
            }
        }

        Text {
            objectName: "spaceHistoryNote"
            Layout.fillWidth: true
            visible: text !== ""
            wrapMode: Text.Wrap
            text: {
                if (Spaces.history.failed)
                    return qsTr("The history could not be loaded.");
                if (Spaces.history.versions.count > 0)
                    return panel.trashed ? qsTr("This page is in the trash. Restore it to bring back a version.") : "";
                return Spaces.history.loading ? qsTr("Loading the history…") : qsTr("This page has no versions yet.");
            }
            color: panel.muted
            font.pixelSize: Math.round(13 * Theme.fontScale)
        }

        ShellButton {
            objectName: "spaceHistoryRetry"
            visible: Spaces.history.failed
            text: qsTr("Try again")
            onClicked: Shell.dispatch("space.history.open", { pageId: Spaces.pageId })
        }

        ListView {
            objectName: "spaceHistoryList"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 8
            model: Spaces.history.versions
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
                id: row

                required property int index
                required property var version
                required property string at
                required property bool byAgent
                required property bool byUpdate
                required property bool byFile
                required property string threadTitle
                required property string restoredFromAt
                readonly property bool newest: index === 0
                readonly property bool open: Spaces.history.reading && Spaces.history.version.version === version

                objectName: "spaceHistoryRow:" + index
                width: ListView.view.width
                implicitHeight: content.implicitHeight + 16
                radius: Math.min(Theme.radius, 8)
                color: Theme.palette.color("surfaceRaised", "#18181b")
                border.color: row.open ? Theme.palette.color("focus", "#3b82f6") : panel.lineColor

                MouseArea {
                    id: rowArea

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Shell.dispatch("space.history.read", { version: row.version })
                }

                ColumnLayout {
                    id: content

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 8
                    spacing: 4

                    Text {
                        Layout.fillWidth: true
                        text: Qt.formatDateTime(new Date(row.at), Qt.locale().dateTimeFormat(Locale.ShortFormat))
                        elide: Text.ElideRight
                        color: panel.foreground
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                    }

                    Text {
                        Layout.fillWidth: true
                        text: {
                            const author = row.byUpdate ? qsTr("The page's update") : row.byFile ? qsTr("The project file") : !row.byAgent ? qsTr("You") : row.threadTitle !== "" ? row.threadTitle : qsTr("An agent");
                            return row.newest ? qsTr("%1 · current").arg(author) : author;
                        }
                        elide: Text.ElideRight
                        color: panel.muted
                        font.pixelSize: Math.round(11 * Theme.fontScale)
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: row.restoredFromAt !== ""
                        text: qsTr("Restored from %1").arg(Qt.formatDateTime(new Date(row.restoredFromAt), Qt.locale().dateTimeFormat(Locale.ShortFormat)))
                        elide: Text.ElideRight
                        color: panel.muted
                        font.pixelSize: Math.round(11 * Theme.fontScale)
                    }

                    ShellButton {
                        objectName: "spaceHistoryRestore:" + row.index
                        Layout.alignment: Qt.AlignRight
                        visible: !row.newest && !panel.trashed
                        subtle: true
                        iconName: "rotate-ccw"
                        text: qsTr("Restore")
                        implicitHeight: 24
                        onClicked: Shell.dispatch("space.history.restore", { version: row.version })
                    }
                }
            }

            footer: Item {
                width: ListView.view.width
                height: Spaces.history.hasMore ? moreButton.implicitHeight + 8 : 0

                ShellButton {
                    id: moreButton

                    objectName: "spaceHistoryMore"
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    visible: Spaces.history.hasMore
                    enabled: !Spaces.history.loading
                    subtle: true
                    text: qsTr("Load more")
                    onClicked: Shell.dispatch("space.history.more", {})
                }
            }
        }
    }
}
