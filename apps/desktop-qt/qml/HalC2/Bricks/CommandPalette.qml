import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import "js/settingsPages.js" as Pages

// The command palette (PaletteModel, CommandPaletteController): a search field over
// its grouped list. Up and Down move the highlight, Enter runs it, mod+1..9
// run the Nth entry, and Escape or a click outside dismisses it, which gives
// the composer the keyboard back.
Popup {
    id: popup

    objectName: "commandPalette"
    parent: Overlay.overlay
    // Not modal, so the window's shortcuts (mod+k among them) still reach it.
    modal: false
    x: Math.round(((parent?.width ?? width) - width) / 2)
    y: Math.round((parent?.height ?? 0) * 0.12)
    width: Math.min(640, (parent?.width ?? 672) - 32)
    height: Math.min(480, (parent?.height ?? 512) - y - 16)
    padding: 8
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    Component.onCompleted: PaletteModel.setSettingsSections(Pages.sections)

    Connections {
        target: PaletteModel
        function onOpenChanged() {
            PaletteModel.open ? popup.open() : popup.close();
        }
        function onHighlightedChanged() {
            list.positionViewAtIndex(PaletteModel.highlighted, ListView.Contain);
        }
    }

    onOpened: {
        field.text = "";
        field.forceActiveFocus();
    }
    // Escape, a click outside, or the palette's own toggle.
    onClosed: {
        if (PaletteModel.open) PaletteModel.dismiss();
    }

    background: Rectangle {
        color: Theme.palette.color("surfaceOverlay", "#18181b")
        border.color: Theme.palette.color("border", "#27272a")
        radius: Math.min(Theme.radius, 16)
    }

    contentItem: ColumnLayout {
        spacing: 8

        ShellTextField {
            id: field

            objectName: "commandPaletteSearch"
            Layout.fillWidth: true
            implicitHeight: 36
            placeholderText: qsTr("Search commands, projects, and threads...")
            onTextEdited: PaletteModel.query = text

            // mod+1..9 are the window's thread jumps otherwise.
            Keys.onShortcutOverride: event => {
                event.accepted = (event.modifiers & Qt.ControlModifier) && event.key >= Qt.Key_1 && event.key <= Qt.Key_9;
            }
            Keys.onPressed: event => {
                if ((event.modifiers & Qt.ControlModifier) && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
                    PaletteModel.run(event.key - Qt.Key_1);
                } else if (event.key === Qt.Key_Down) {
                    PaletteModel.move(1);
                } else if (event.key === Qt.Key_Up) {
                    PaletteModel.move(-1);
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    PaletteModel.runHighlighted();
                } else {
                    return;
                }
                event.accepted = true;
            }
        }

        ListView {
            id: list

            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: PaletteModel
            currentIndex: PaletteModel.highlighted
            boundsBehavior: Flickable.StopAtBounds
            section.property: "group"
            section.delegate: Text {
                required property string section

                width: ListView.view.width
                topPadding: 8
                bottomPadding: 4
                leftPadding: 8
                text: section
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: 11
                font.weight: Font.DemiBold
            }

            delegate: Rectangle {
                id: row

                required property int index
                required property string title
                required property string description
                required property string shortcut

                width: ListView.view.width
                implicitHeight: 34
                radius: Math.min(Theme.radius, 8)
                color: index === PaletteModel.highlighted ? Theme.palette.color("accentSurface", "#2a2a30") : "transparent"

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    spacing: 8

                    Text {
                        text: row.title
                        color: Theme.palette.color("text", "#e4e4e7")
                        font.pixelSize: 13
                        elide: Text.ElideRight
                        Layout.maximumWidth: row.width * 0.6
                    }
                    Text {
                        Layout.fillWidth: true
                        text: row.description
                        color: Theme.palette.color("textMuted", "#a1a1aa")
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }
                    Text {
                        visible: text.length > 0
                        text: row.shortcut
                        color: Theme.palette.color("textMuted", "#a1a1aa")
                        font.pixelSize: 11
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: PaletteModel.highlighted = row.index
                    onClicked: PaletteModel.run(row.index)
                }
            }

            Text {
                anchors.centerIn: parent
                visible: list.count === 0
                text: PaletteModel.emptyText
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: 13
            }
        }
    }
}
