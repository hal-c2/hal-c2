pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// One block of the open page in the phone layout. Its text is edited where it
// is and goes to the MC when the editor loses focus; a checklist item is ticked
// by its box and a link opens its page. Moving, deleting and commenting are in
// the menu at its end, where a desktop's hover would have them.
Rectangle {
    id: row

    required property var model
    required property int index
    required property string kind
    required property string text
    required property bool checked
    required property string linkedPageId
    required property string linkedTitle
    required property bool byAgent
    required property int openComments
    // A page in the trash is only read.
    property bool readOnly: false
    readonly property string blockId: model.id
    readonly property bool editing: editor.activeFocus

    signal menuRequested
    signal linkOpened
    signal commentsRequested

    function commit() {
        if (kind !== "subpage_link" && editor.text !== text)
            Shell.dispatch("space.block.update", { blockId: blockId, text: editor.text });
    }

    // What the MC wrote shows unless the user is writing here.
    onTextChanged: {
        if (!editor.activeFocus)
            editor.text = text;
    }
    // Scrolled away or the screen left mid-edit: what was written still counts.
    Component.onDestruction: commit()

    implicitHeight: Math.max(52, content.implicitHeight + 8)
    color: kind === "callout" ? Qt.alpha(Theme.palette.color("info", "#3b82f6"), Theme.appearance === "dark" ? 0.14 : 0.08) : "transparent"
    objectName: "spaceBlock:" + text

    RowLayout {
        id: content

        anchors.fill: parent
        anchors.leftMargin: row.kind === "checklist" ? 4 : 16
        anchors.rightMargin: 4
        spacing: 4

        CheckBox {
            objectName: "spaceTick:" + row.text
            visible: row.kind === "checklist"
            enabled: !row.readOnly
            checked: row.checked
            Accessible.name: row.text
            onToggled: {
                Shell.dispatch("space.block.setChecked", { blockId: row.blockId, checked: checked });
                checked = Qt.binding(() => row.checked);
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: 2

            TextEdit {
                id: editor

                objectName: "spaceBlockEditor:" + row.text
                Layout.fillWidth: true
                visible: row.kind !== "subpage_link"
                readOnly: row.readOnly
                wrapMode: TextEdit.Wrap
                color: Theme.palette.color("text", "#e4e4e7")
                selectionColor: Theme.palette.color("accent", "#2563eb")
                opacity: row.kind === "checklist" && row.checked ? 0.6 : 1
                font.pixelSize: Math.round((row.kind === "heading" ? 20 : 15) * Theme.fontScale)
                font.weight: row.kind === "heading" ? Font.DemiBold : Font.Normal
                font.strikeout: row.kind === "checklist" && row.checked
                Accessible.name: qsTr("Block text")
                Component.onCompleted: text = row.text
                onActiveFocusChanged: {
                    if (activeFocus)
                        return;
                    row.commit();
                    text = row.text;
                }
                // A heading or a checklist item is one line.
                Keys.onReturnPressed: event => {
                    if (row.kind === "heading" || row.kind === "checklist")
                        editor.focus = false;
                    else
                        event.accepted = false;
                }
            }

            MobileButton {
                objectName: "spaceLink:" + row.linkedTitle
                visible: row.kind === "subpage_link"
                subtle: true
                text: row.linkedTitle
                onClicked: row.linkOpened()
            }

            Label {
                visible: row.byAgent
                text: qsTr("agent")
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }
        }

        MobileButton {
            objectName: "spaceComment:" + row.text
            visible: row.openComments > 0
            subtle: true
            text: row.openComments
            Accessible.name: qsTr("%n open comment(s)", "", row.openComments)
            onClicked: row.commentsRequested()
        }

        MobileIconButton {
            objectName: "spaceBlockMenu:" + row.text
            visible: !row.readOnly
            iconName: "ellipsis"
            label: qsTr("Actions for this block")
            onClicked: row.menuRequested()
        }
    }
}
