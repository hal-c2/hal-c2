pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// One slide of the open deck in the phone layout. Its title and body are edited
// where they are and go to the MC when the editor loses focus; moving, adding
// and deleting are in the menu at its end.
Rectangle {
    id: row

    required property var model
    required property int index
    required property string title
    required property string body
    // A deck in the trash is only read.
    property bool readOnly: false
    readonly property string slideId: model.id
    readonly property bool editing: titleEditor.activeFocus || bodyEditor.activeFocus
    // The Space it was made in: an edit written as the Space changes still goes there.
    property string spaceId: ""

    // What was last taken from the slide: text that differs is the user's edit,
    // written while the deck was live even if it is in the trash by now.
    property string shownTitle: ""
    property string shownBody: ""

    Component.onCompleted: {
        spaceId = Spaces.spaceId;
        showTitle();
        showBody();
    }

    signal menuRequested

    function showTitle() {
        shownTitle = title;
        titleEditor.text = title;
    }

    function showBody() {
        shownBody = body;
        bodyEditor.text = body;
    }

    function writeTitle() {
        if (titleEditor.text === shownTitle) {
            showTitle();
        } else {
            shownTitle = titleEditor.text;
            Shell.dispatch("space.slide.update", { spaceId: spaceId, slideId: slideId, title: titleEditor.text });
        }
    }

    function writeBody() {
        if (bodyEditor.text === shownBody) {
            showBody();
        } else {
            shownBody = bodyEditor.text;
            Shell.dispatch("space.slide.update", { spaceId: spaceId, slideId: slideId, body: bodyEditor.text });
        }
    }

    // What the MC wrote shows unless the user is writing there.
    onTitleChanged: {
        if (!titleEditor.activeFocus)
            showTitle();
    }
    onBodyChanged: {
        if (!bodyEditor.activeFocus)
            showBody();
    }
    // Scrolled away or the screen left mid-edit: what was written still counts.
    // An editor without focus wrote its text as it lost it.
    Component.onDestruction: {
        if (titleEditor.activeFocus)
            writeTitle();
        if (bodyEditor.activeFocus)
            writeBody();
    }

    implicitHeight: Math.max(76, content.implicitHeight + 16)
    color: "transparent"
    objectName: "spaceSlide:" + index

    RowLayout {
        id: content

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 16
        anchors.rightMargin: 4
        spacing: 8

        Label {
            Layout.alignment: Qt.AlignTop
            text: row.index + 1
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Math.round(14 * Theme.fontScale)
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 6

            TextEdit {
                id: titleEditor

                objectName: "spaceSlideTitle:" + row.index
                Layout.fillWidth: true
                readOnly: row.readOnly
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.PlainText
                color: Theme.palette.color("text", "#e4e4e7")
                selectionColor: Theme.palette.color("accent", "#2563eb")
                font.pixelSize: Math.round(18 * Theme.fontScale)
                font.weight: Font.DemiBold
                Accessible.name: qsTr("Slide title")
                onActiveFocusChanged: {
                    if (!activeFocus)
                        row.writeTitle();
                }
                // A title is one line.
                Keys.onReturnPressed: focus = false

                Label {
                    visible: titleEditor.text === "" && !row.readOnly
                    text: qsTr("Slide title")
                    color: Theme.palette.color("textMuted", "#a1a1aa")
                    font: titleEditor.font
                }
            }

            TextEdit {
                id: bodyEditor

                objectName: "spaceSlideBody:" + row.index
                Layout.fillWidth: true
                readOnly: row.readOnly
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.PlainText
                color: Theme.palette.color("text", "#e4e4e7")
                selectionColor: Theme.palette.color("accent", "#2563eb")
                font.pixelSize: Math.round(15 * Theme.fontScale)
                Accessible.name: qsTr("What the slide says")
                onActiveFocusChanged: {
                    if (!activeFocus)
                        row.writeBody();
                }

                Label {
                    visible: bodyEditor.text === "" && !row.readOnly
                    text: qsTr("What the slide says")
                    color: Theme.palette.color("textMuted", "#a1a1aa")
                    font: bodyEditor.font
                }
            }
        }

        MobileIconButton {
            objectName: "spaceSlideMenu:" + row.index
            Layout.alignment: Qt.AlignTop
            visible: !row.readOnly
            iconName: "ellipsis"
            label: qsTr("Actions for this slide")
            onClicked: row.menuRequested()
        }
    }
}
