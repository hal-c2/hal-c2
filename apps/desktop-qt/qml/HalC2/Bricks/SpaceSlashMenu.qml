pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The kinds of block a page's composer can add, filtered by what follows a
// `/` (`query`). The composer moves the highlight and chooses; a click
// chooses too.
Popup {
    id: menu

    property string query: ""
    property int current: 0
    readonly property var kinds: [
        { kind: "paragraph", label: qsTr("Text"), icon: "text-wrap", words: "text paragraph" },
        { kind: "heading", label: qsTr("Heading"), icon: "hash", words: "heading title" },
        { kind: "checklist", label: qsTr("Checklist"), icon: "square-check", words: "checklist todo task" },
        { kind: "callout", label: qsTr("Callout"), icon: "info", words: "callout note" },
        { kind: "subpage_link", label: qsTr("Link to a subpage"), icon: "link", words: "link subpage page" }
    ]
    readonly property var shown: kinds.filter(entry => query.length === 0 || entry.label.toLowerCase().startsWith(query.toLowerCase()) || entry.words.split(" ").some(word => word.startsWith(query.toLowerCase())))

    signal chosen(string kind)

    function move(delta) {
        if (shown.length > 0)
            current = (current + delta + shown.length) % shown.length;
    }

    // Chooses the highlighted kind; false when none is shown.
    function choose() {
        if (shown.length === 0)
            return false;
        chosen(shown[Math.min(current, shown.length - 1)].kind);
        close();
        return true;
    }

    onQueryChanged: current = 0
    onAboutToShow: current = 0
    padding: 4
    width: 240
    // The composer keeps the keyboard.
    focus: false
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

    background: Rectangle {
        radius: Math.min(Theme.radius, 8)
        color: Theme.palette.color("surfaceOverlay", "#18181b")
        border.color: Theme.palette.color("border", "#27272a")
    }

    contentItem: ColumnLayout {
        spacing: 0

        Text {
            Layout.margins: 8
            visible: menu.shown.length === 0
            text: qsTr("No block kind matches")
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Math.round(13 * Theme.fontScale)
        }

        Repeater {
            model: menu.shown

            delegate: Rectangle {
                id: entry

                required property var modelData
                required property int index

                objectName: "spaceSlash:" + modelData.kind
                Accessible.role: Accessible.MenuItem
                Accessible.name: modelData.label
                Accessible.focused: index === menu.current
                Accessible.onPressAction: {
                    menu.current = entry.index;
                    menu.choose();
                }
                Layout.fillWidth: true
                implicitHeight: 30
                radius: Math.min(Theme.radius, 6)
                color: index === menu.current ? Theme.palette.color("accentSurface", "#27272a") : "transparent"

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    spacing: 8

                    ShellIcon {
                        name: entry.modelData.icon
                        size: 14
                        color: Theme.palette.color("iconMuted", "#a1a1aa")
                    }

                    Text {
                        Layout.fillWidth: true
                        text: entry.modelData.label
                        color: Theme.palette.color("text", "#e4e4e7")
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: menu.current = entry.index
                    onClicked: {
                        menu.current = entry.index;
                        menu.choose();
                    }
                }
            }
        }
    }
}
