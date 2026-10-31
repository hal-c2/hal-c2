pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// One block of a page (a row of Spaces.blocks): its text edited in place and
// written when the user leaves it or presses Return, a checklist item's tick,
// a callout's tint, a subpage link that opens the page, and the block's own
// actions (comment, add a block below, move up or down, delete).
Item {
    id: block

    required property string blockId
    required property string kind
    required property string text
    required property bool checked
    required property string linkedPageId
    required property string linkedTitle
    required property bool byAgent
    required property int openComments
    // Where it is on the page, and the blocks either side ("" at an end).
    required property int index
    property string previousId: ""
    property string beforePreviousId: ""
    property string nextId: ""
    property bool readOnly: false

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color info: Theme.palette.color("info", "#3b82f6")
    readonly property bool editing: editor.activeFocus

    signal commentRequested(string blockId)
    signal addBelowRequested(string blockId)

    // Writes what the user typed, if it differs from the block's text.
    function commit() {
        const typed = editor.text;
        if (typed !== block.text && !block.readOnly)
            Shell.dispatch("space.block.update", { blockId: block.blockId, text: typed });
    }

    objectName: "spaceBlock:" + text
    implicitHeight: Math.max(row.implicitHeight, 28) + (block.kind === "heading" ? 10 : 4)

    // The editor follows the block while the user is not writing in it.
    onTextChanged: {
        if (!editor.activeFocus)
            editor.text = block.text;
    }

    HoverHandler {
        id: hover
    }

    Rectangle {
        anchors.fill: parent
        anchors.topMargin: 1
        anchors.bottomMargin: 1
        radius: Math.min(Theme.radius, 8)
        visible: block.kind === "callout"
        color: Qt.alpha(block.info, Theme.appearance === "dark" ? 0.14 : 0.08)
        border.color: Qt.alpha(block.info, 0.4)
    }

    RowLayout {
        id: row

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: block.kind === "callout" ? 10 : 0
        spacing: 8

        ShellCheckBox {
            objectName: "spaceTick:" + block.text
            Accessible.name: block.text
            visible: block.kind === "checklist"
            padding: 0
            checked: block.checked
            enabled: !block.readOnly
            onToggled: {
                Shell.dispatch("space.block.setChecked", { blockId: block.blockId, checked: checked });
                // The pending tick, then the stream, says what it is.
                checked = Qt.binding(() => block.checked);
            }
        }

        ShellIcon {
            visible: block.kind === "callout"
            name: "info"
            size: 16
            color: block.info
        }

        ShellIcon {
            visible: block.kind === "subpage_link"
            name: "file-text"
            size: 16
            color: block.muted
        }

        Text {
            id: link

            objectName: "spaceLink:" + block.linkedTitle
            Layout.fillWidth: true
            visible: block.kind === "subpage_link"
            text: block.linkedTitle
            color: Theme.palette.color("accent", "#3b82f6")
            font.pixelSize: Math.round(15 * Theme.fontScale)
            font.underline: linkMouse.containsMouse
            elide: Text.ElideRight

            MouseArea {
                id: linkMouse

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Shell.dispatch("space.selectPage", { pageId: block.linkedPageId })
            }
        }

        TextEdit {
            id: editor

            objectName: "spaceBlockEditor:" + block.text
            Layout.fillWidth: true
            visible: block.kind !== "subpage_link"
            readOnly: block.readOnly
            wrapMode: TextEdit.Wrap
            selectByMouse: true
            color: block.foreground
            selectionColor: Theme.palette.color("accent", "#2563eb")
            selectedTextColor: Theme.palette.color("accentForeground", "#ffffff")
            font.pixelSize: Math.round((block.kind === "heading" ? 20 : 15) * Theme.fontScale)
            font.weight: block.kind === "heading" ? Font.DemiBold : Font.Normal
            font.strikeout: block.kind === "checklist" && block.checked
            opacity: block.kind === "checklist" && block.checked ? 0.7 : 1
            Component.onCompleted: text = block.text
            onActiveFocusChanged: {
                if (!activeFocus) {
                    block.commit();
                    editor.text = block.text;
                }
            }
            // Return writes the block (by leaving it); Shift+Return starts a
            // new line in it.
            Keys.onReturnPressed: event => {
                if (event.modifiers & Qt.ShiftModifier) {
                    event.accepted = false;
                    return;
                }
                editor.focus = false;
            }
            Keys.onEscapePressed: {
                editor.text = block.text;
                editor.focus = false;
            }
        }

        Text {
            visible: block.byAgent
            text: qsTr("agent")
            color: block.muted
            font.pixelSize: Math.round(11 * Theme.fontScale)
        }

        RowLayout {
            spacing: 0
            // Kept in the layout so the text does not reflow on hover.
            opacity: hover.hovered || block.editing || block.openComments > 0 ? 1 : 0

            ShellButton {
                objectName: "spaceComment:" + block.text
                subtle: true
                iconName: "message-square-plus"
                text: block.openComments > 0 ? String(block.openComments) : ""
                implicitHeight: 26
                toolTip: qsTr("Comment")
                Accessible.name: block.openComments > 0 ? qsTr("Comments, %1 open").arg(block.openComments) : qsTr("Comment")
                onClicked: block.commentRequested(block.blockId)
            }

            ShellButton {
                objectName: "spaceAddBelow:" + block.text
                subtle: true
                iconName: "plus"
                implicitHeight: 26
                implicitWidth: 26
                Accessible.name: qsTr("Add a block below")
                visible: !block.readOnly
                onClicked: block.addBelowRequested(block.blockId)
            }

            ShellButton {
                objectName: "spaceMoveUp:" + block.text
                subtle: true
                iconName: "arrow-up"
                implicitHeight: 26
                implicitWidth: 26
                Accessible.name: qsTr("Move up")
                visible: !block.readOnly
                enabled: block.previousId !== ""
                // After the block before the one above it; first when there is none.
                onClicked: Shell.dispatch("space.block.move", { blockId: block.blockId, afterBlockId: block.beforePreviousId })
            }

            ShellButton {
                objectName: "spaceMoveDown:" + block.text
                subtle: true
                iconName: "arrow-down"
                implicitHeight: 26
                implicitWidth: 26
                Accessible.name: qsTr("Move down")
                visible: !block.readOnly
                enabled: block.nextId !== ""
                onClicked: Shell.dispatch("space.block.move", { blockId: block.blockId, afterBlockId: block.nextId })
            }

            ShellButton {
                objectName: "spaceDeleteBlock:" + block.text
                subtle: true
                iconName: "x"
                implicitHeight: 26
                implicitWidth: 26
                Accessible.name: qsTr("Delete block")
                visible: !block.readOnly
                onClicked: Shell.dispatch("space.block.delete", { blockId: block.blockId })
            }
        }
    }
}
