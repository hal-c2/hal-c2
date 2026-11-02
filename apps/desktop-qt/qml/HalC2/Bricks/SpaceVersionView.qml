pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// A version of the open page being read (Spaces.history), in the page's place:
// nothing in it can be changed. The way out is back to the page, or restoring
// it, which is a new edit like any other.
Rectangle {
    id: view

    objectName: "spaceVersionView"

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property var version: Spaces.history.version
    readonly property bool arrived: view.version.version !== undefined
    // The newest version is the page as it is, so there is nothing to bring back.
    readonly property bool newest: Spaces.history.versions.count > 0 && Spaces.history.versions.get(0).version === view.version.version

    color: Theme.palette.color("canvas", "#09090b")

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: banner.implicitHeight + 16
            color: Theme.palette.color("surfaceRaised", "#18181b")

            RowLayout {
                id: banner

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: 12
                spacing: 8

                ShellButton {
                    objectName: "spaceVersionBack"
                    subtle: true
                    iconName: "chevron-left"
                    text: qsTr("Back to the page")
                    onClicked: Shell.dispatch("space.history.back", {})
                }

                Text {
                    objectName: "spaceVersionWhen"
                    Layout.fillWidth: true
                    text: view.arrived ? qsTr("The page as it was on %1").arg(Qt.formatDateTime(new Date(view.version.at), Qt.locale().dateTimeFormat(Locale.ShortFormat))) : qsTr("Loading this version…")
                    elide: Text.ElideRight
                    color: view.muted
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                }

                ShellButton {
                    objectName: "spaceVersionRestore"
                    visible: view.arrived && !view.newest && Spaces.page.trashed !== true
                    primary: true
                    iconName: "rotate-ccw"
                    text: qsTr("Restore")
                    onClicked: Shell.dispatch("space.history.restore", { version: view.version.version })
                }
            }
        }

        ListView {
            objectName: "spaceVersionBlocks"
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.leftMargin: 32
            Layout.rightMargin: 32
            clip: true
            spacing: 2
            model: Spaces.history.blocks
            boundsBehavior: Flickable.StopAtBounds
            bottomMargin: 24

            header: Text {
                objectName: "spaceVersionTitle"
                width: ListView.view.width
                bottomPadding: 16
                topPadding: 24
                text: view.version.title ?? ""
                elide: Text.ElideRight
                color: view.foreground
                font.pixelSize: Math.round(28 * Theme.fontScale)
                font.weight: Font.Bold
            }

            delegate: SpaceBlock {
                required property var model

                width: ListView.view.width
                blockId: model.id
                level: model.level ?? 0
                language: model.language ?? ""
                chart: model.chart ?? ({})
                readOnly: true
            }
        }
    }
}
