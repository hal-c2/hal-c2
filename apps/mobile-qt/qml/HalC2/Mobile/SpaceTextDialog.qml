import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell

// Asks for a name, a block's text, a comment or Markdown to import: `ask` shows
// it with the words given ({ title, placeholder, text, action, multiline }) and
// calls back with what was written. Centred in its parent, so it stays clear of
// the keyboard when the parent does.
Dialog {
    id: dialog

    property string placeholder: ""
    property string action: ""
    property bool multiline: false
    property var then: null
    // What an on-screen keyboard is still composing counts as written.
    readonly property string written: (field.text + field.preeditText).trim()

    function ask(words, answer) {
        title = words.title;
        placeholder = words.placeholder ?? "";
        action = words.action;
        multiline = words.multiline === true;
        then = answer;
        field.text = words.text ?? "";
        open();
        field.selectAll();
        field.forceActiveFocus();
    }

    function save() {
        Qt.inputMethod.commit();
        if (field.text.trim().length > 0)
            accept();
    }

    objectName: "spaceTextDialog"
    modal: true
    anchors.centerIn: parent
    width: Math.min(parent.width - 32, 420)
    height: Math.min(implicitHeight, parent.height - 16)
    padding: 20
    onAccepted: then(field.text.trim())

    background: MobileSurface {}
    Overlay.modal: Rectangle {
        color: Qt.rgba(0, 0, 0, 0.5)
    }
    header: Label {
        text: dialog.title
        padding: 20
        bottomPadding: 0
        font.pixelSize: Math.round(18 * Theme.fontScale)
        font.weight: Font.DemiBold
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 16

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 48
            Layout.preferredHeight: dialog.multiline ? 200 : 56

            TextArea {
                id: field

                objectName: "spaceTextField"
                wrapMode: TextEdit.Wrap
                placeholderText: dialog.placeholder
                Accessible.name: dialog.title
                // A name is one line; what can run to several keeps the key.
                Keys.onReturnPressed: event => {
                    if (dialog.multiline)
                        event.accepted = false;
                    else
                        dialog.save();
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Item {
                Layout.fillWidth: true
            }

            MobileButton {
                objectName: "spaceTextCancel"
                subtle: true
                text: qsTr("Cancel")
                onClicked: dialog.reject()
            }

            MobileButton {
                objectName: "spaceTextSave"
                primary: true
                enabled: dialog.written.length > 0
                text: dialog.action
                onClicked: dialog.save()
            }
        }
    }
}
