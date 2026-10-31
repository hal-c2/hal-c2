pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// A Space screen's choices as a sheet from the bottom edge, with rows a finger
// wide: `ask` shows the rows ({ id, label, icon, destructive, enabled }) and
// calls back with the id chosen. Closing it any other way chooses nothing.
Popup {
    id: sheet

    property var rows: []
    property var chosen: null

    function ask(choices, then) {
        rows = choices;
        chosen = then;
        open();
    }

    function choose(id) {
        const then = chosen;
        close();
        then(id);
    }

    objectName: "spaceSheet"
    modal: true
    // With the keyboard's focus, the system's back closes it.
    focus: true
    x: (parent.width - width) / 2
    y: parent.height - height
    width: Math.min(parent.width, 520)
    height: Math.min(implicitHeight, parent.height - 24)
    padding: 0
    topPadding: 8
    bottomPadding: 8

    background: MobileSurface {}
    Overlay.modal: Rectangle {
        color: Qt.rgba(0, 0, 0, 0.5)
    }

    contentItem: ListView {
        implicitHeight: contentHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: sheet.rows

        delegate: ItemDelegate {
            id: row

            required property var modelData
            readonly property color tint: Theme.palette.color(modelData.destructive === true ? "error" : "text", "#e4e4e7")

            objectName: "spaceSheetItem:" + modelData.id
            width: ListView.view.width
            height: 48
            enabled: modelData.enabled !== false
            Accessible.name: modelData.label
            onClicked: sheet.choose(modelData.id)

            contentItem: RowLayout {
                spacing: 16

                ShellIcon {
                    visible: (row.modelData.icon ?? "") !== ""
                    name: row.modelData.icon ?? ""
                    size: 18
                    color: Qt.alpha(row.tint, row.enabled ? 0.8 : 0.4)
                }

                Label {
                    Layout.fillWidth: true
                    text: row.modelData.label
                    elide: Text.ElideRight
                    color: Qt.alpha(row.tint, row.enabled ? 1 : 0.5)
                    font.pixelSize: Math.round(15 * Theme.fontScale)
                }
            }
        }
    }
}
