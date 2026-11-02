pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The open page's versions (Spaces.history), newest first: each says when it was
// written and by whom, opens to be read, and all but the newest, which is the
// page as it is, can be restored.
ColumnLayout {
    id: view

    required property Item screen
    readonly property bool trashed: (Spaces.page ?? {}).trashed === true

    objectName: "spaceHistoryView"
    spacing: 0

    MobileBar {
        Layout.fillWidth: true
        title: qsTr("History")
        canGoBack: true
        onBackRequested: view.screen.backRequested()
    }

    Label {
        objectName: "spaceHistoryNote"
        Layout.fillWidth: true
        padding: 16
        visible: text !== ""
        wrapMode: Text.Wrap
        color: Theme.palette.color("textMuted", "#a1a1aa")
        font.pixelSize: Math.round(14 * Theme.fontScale)
        text: {
            if (Spaces.history.failed)
                return qsTr("The history could not be loaded.");
            if (Spaces.history.versions.count > 0)
                return view.trashed ? qsTr("This page is in the trash. Restore it to bring back a version.") : "";
            return Spaces.history.loading ? qsTr("Loading the history…") : qsTr("This page has no versions yet.");
        }
    }

    MobileButton {
        objectName: "spaceHistoryRetry"
        Layout.alignment: Qt.AlignHCenter
        visible: Spaces.history.failed
        text: qsTr("Try again")
        onClicked: Shell.dispatch("space.history.open", { pageId: Spaces.pageId })
    }

    ListView {
        objectName: "spaceHistoryList"
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: Spaces.history.versions

        delegate: ItemDelegate {
            id: row

            required property int index
            required property var version
            required property string at
            required property bool byAgent
            required property bool byUpdate
            required property string threadTitle
            required property string restoredFromAt
            readonly property bool newest: index === 0

            objectName: "spaceHistoryRow:" + index
            width: ListView.view.width
            implicitHeight: Math.max(64, content.implicitHeight + 16)
            leftPadding: 16
            rightPadding: 4
            topPadding: 8
            bottomPadding: 8
            onClicked: view.screen.readVersion(version)

            contentItem: RowLayout {
                id: content

                spacing: 8

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    Label {
                        Layout.fillWidth: true
                        text: Qt.formatDateTime(new Date(row.at), Qt.locale().dateTimeFormat(Locale.ShortFormat))
                        elide: Text.ElideRight
                        font.pixelSize: Math.round(15 * Theme.fontScale)
                    }

                    Label {
                        Layout.fillWidth: true
                        text: {
                            const author = row.byUpdate ? qsTr("The page's update") : !row.byAgent ? qsTr("You") : row.threadTitle !== "" ? row.threadTitle : qsTr("An agent");
                            return row.newest ? qsTr("%1 · current").arg(author) : author;
                        }
                        elide: Text.ElideRight
                        color: Theme.palette.color("textMuted", "#a1a1aa")
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                    }

                    Label {
                        Layout.fillWidth: true
                        visible: row.restoredFromAt !== ""
                        text: qsTr("Restored from %1").arg(Qt.formatDateTime(new Date(row.restoredFromAt), Qt.locale().dateTimeFormat(Locale.ShortFormat)))
                        elide: Text.ElideRight
                        color: Theme.palette.color("textMuted", "#a1a1aa")
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                    }
                }

                MobileIconButton {
                    objectName: "spaceHistoryRestore:" + row.index
                    visible: !row.newest && !view.trashed
                    iconName: "rotate-ccw"
                    label: qsTr("Restore")
                    onClicked: Shell.dispatch("space.history.restore", { version: row.version })
                }
            }
        }

        footer: Item {
            width: ListView.view.width
            height: Spaces.history.hasMore ? more.implicitHeight + 16 : 0

            MobileButton {
                id: more

                objectName: "spaceHistoryMore"
                anchors.centerIn: parent
                visible: Spaces.history.hasMore
                enabled: !Spaces.history.loading
                text: qsTr("Load more")
                onClicked: Shell.dispatch("space.history.more", {})
            }
        }
    }
}
