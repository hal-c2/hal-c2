import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// Which of the terminal's visible lines go to the draft (`mobileTerminal.context`,
// MobileTerminal): all of them to begin with, or between two tapped ones.
Popup {
    id: sheet

    readonly property var context: (Shell.state.mobileTerminal ?? {}).context ?? null

    objectName: "terminalContextSheet"
    visible: context !== null
    modal: true
    focus: true
    closePolicy: Popup.NoAutoClose
    x: (parent.width - width) / 2
    y: parent.height - height
    width: Math.min(parent.width, 520)
    height: Math.min(implicitHeight, parent.height - 24)
    padding: 12

    background: MobileSurface {}
    Overlay.modal: Rectangle {
        color: Qt.rgba(0, 0, 0, 0.5)
    }

    contentItem: ColumnLayout {
        spacing: 8

        Label {
            Layout.fillWidth: true
            text: qsTr("Visible terminal output")
            font.weight: Font.DemiBold
            color: Theme.palette.color("text", "#e4e4e7")
        }

        Label {
            objectName: "terminalContextHint"
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: sheet.context !== null && sheet.context.tooLarge ? qsTr("Select fewer lines to fit the context limit.") : qsTr("Tap the first and last line to select a range.")
            color: Theme.palette.color(sheet.context !== null && sheet.context.tooLarge ? "error" : "textMuted", "#a1a1aa")
        }

        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            implicitHeight: Math.min(contentHeight, 360)
            clip: true
            model: sheet.context !== null ? sheet.context.lines : []

            delegate: ItemDelegate {
                id: line

                required property int index
                required property string modelData
                readonly property bool selected: sheet.context !== null && index >= sheet.context.start && index <= sheet.context.end

                objectName: "terminalContextLine:" + index
                width: ListView.view.width
                height: 32
                highlighted: selected
                checkable: false
                onClicked: Shell.dispatch("mobileTerminal.context.tap", { index: line.index })

                contentItem: Text {
                    text: line.modelData
                    elide: Text.ElideRight
                    font.family: Theme.fontTerminal.length > 0 ? Theme.fontTerminal : "monospace"
                    color: Theme.palette.color(line.selected ? "text" : "textMuted", "#e4e4e7")
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            MobileButton {
                objectName: "terminalContextCancel"
                Layout.fillWidth: true
                subtle: true
                text: qsTr("Cancel")
                onClicked: Shell.dispatch("mobileTerminal.context.cancel")
            }

            MobileButton {
                objectName: "terminalContextAttach"
                Layout.fillWidth: true
                enabled: sheet.context !== null && !sheet.context.tooLarge
                text: qsTr("Attach selected output")
                onClicked: Shell.dispatch("mobileTerminal.context.attach")
            }
        }
    }
}
