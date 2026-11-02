pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// A version of the open page being read (Spaces.history): nothing in it can be
// changed. The way out is back to the versions, or restoring it, which is a new
// edit like any other.
ColumnLayout {
    id: view

    required property Item screen
    readonly property var version: Spaces.history.version
    readonly property bool arrived: version.version !== undefined
    // The newest version is the page as it is, so there is nothing to bring back.
    readonly property bool newest: Spaces.history.versions.count > 0 && Spaces.history.versions.get(0).version === version.version

    objectName: "spaceVersionScreen"
    spacing: 0

    MobileBar {
        Layout.fillWidth: true
        title: view.version.title ?? ""
        canGoBack: true
        onBackRequested: view.screen.backRequested()

        MobileIconButton {
            objectName: "spaceVersionRestore"
            visible: view.arrived && !view.newest && (Spaces.page ?? {}).trashed !== true
            iconName: "rotate-ccw"
            label: qsTr("Restore")
            onClicked: Shell.dispatch("space.history.restore", { version: view.version.version })
        }
    }

    Label {
        objectName: "spaceVersionWhen"
        Layout.fillWidth: true
        padding: 16
        elide: Text.ElideRight
        color: Theme.palette.color("textMuted", "#a1a1aa")
        font.pixelSize: Math.round(13 * Theme.fontScale)
        text: view.arrived ? qsTr("The page as it was on %1").arg(Qt.formatDateTime(new Date(view.version.at), Qt.locale().dateTimeFormat(Locale.ShortFormat))) : qsTr("Loading this version…")
    }

    ListView {
        objectName: "spaceVersionBlocks"
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: Spaces.history.blocks

        delegate: SpaceBlockRow {
            width: ListView.view.width
            readOnly: true
        }
    }
}
