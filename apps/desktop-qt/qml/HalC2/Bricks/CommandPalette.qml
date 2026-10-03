import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import "js/settingsPages.js" as Pages

// The command palette (PaletteModel, CommandPaletteController): a search field over
// its grouped list, in any of its modes (commands, go to file, project
// search, browsing for a folder). Up and Down move the highlight, Enter runs
// it, mod+1..9 run the Nth entry, Backspace on an empty field leaves a
// submenu, and Escape steps back (a mode to commands, a submenu to the root)
// or dismisses it, as a click outside does, which gives the composer the
// keyboard back. In browse mode mod+Enter adds the typed folder.
Popup {
    id: popup

    objectName: "commandPalette"
    parent: Overlay.overlay
    // Not modal, so the window's shortcuts (mod+k among them) still reach it.
    modal: false
    scale: Shell.state.layout?.zoom ?? 1
    transformOrigin: Item.TopLeft
    x: Math.round(((parent?.width ?? width) - width * scale) / 2)
    y: Math.round((parent?.height ?? 0) * 0.12)
    width: Math.min(640, (parent?.width ?? 672) / scale - 32)
    height: Math.min(480, ((parent?.height ?? 512) - y) / scale - 16)
    padding: 8
    closePolicy: Popup.CloseOnPressOutside

    Component.onCompleted: PaletteModel.setSettingsSections(Pages.paletteEntries(Qt.platform.os))

    Connections {
        target: PaletteModel
        function onOpenChanged() {
            PaletteModel.open ? popup.open() : popup.close();
        }
        function onHighlightedChanged() {
            if (PaletteModel.highlighted >= 0) list.positionViewAtIndex(PaletteModel.highlighted, ListView.Contain);
        }
        // A submenu, a mode or a folder the palette moved to.
        function onQueryChanged() {
            if (field.text !== PaletteModel.query) field.text = PaletteModel.query;
        }
    }

    onOpened: {
        field.text = PaletteModel.query;
        field.forceActiveFocus();
    }
    // A click outside, or the palette's own toggle.
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

        Text {
            objectName: "commandPaletteSubmenu"
            visible: PaletteModel.submenu.length > 0
            text: PaletteModel.submenu
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: 11
            font.weight: Font.DemiBold
            leftPadding: 4
        }

        ShellTextField {
            id: field

            objectName: "commandPaletteSearch"
            Layout.fillWidth: true
            implicitHeight: 36
            placeholderText: PaletteModel.placeholder
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
                } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
                    PaletteModel.addBrowsedFolder();
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    PaletteModel.runHighlighted();
                } else if (event.key === Qt.Key_Escape) {
                    PaletteModel.back();
                } else if (event.key === Qt.Key_Backspace && field.text.length === 0) {
                    if (!PaletteModel.leaveSubmenu()) return;
                } else {
                    return;
                }
                event.accepted = true;
            }
        }

        // A thread search names the environments it could not reach.
        Text {
            visible: PaletteModel.mode === "command" && text.length > 0
            Layout.fillWidth: true
            text: PaletteModel.status
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: 11
            leftPadding: 4
            elide: Text.ElideRight
        }

        // Project search: its options and how many matches it found.
        RowLayout {
            visible: PaletteModel.mode === "content"
            Layout.fillWidth: true
            spacing: 4

            Text {
                Layout.fillWidth: true
                text: PaletteModel.status
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: 11
                leftPadding: 4
                elide: Text.ElideRight
            }
            Repeater {
                model: [
                    { key: "caseSensitive", label: "Aa", tip: qsTr("Match case") },
                    { key: "wholeWord", label: "ab", tip: qsTr("Match whole word") },
                    { key: "useRegex", label: ".*", tip: qsTr("Use regular expression") }
                ]
                delegate: Button {
                    required property var modelData

                    objectName: "commandPalette:" + modelData.key
                    text: modelData.label
                    checkable: true
                    checked: PaletteModel[modelData.key]
                    focusPolicy: Qt.NoFocus
                    implicitHeight: 24
                    implicitWidth: 32
                    font.pixelSize: 11
                    ToolTip.visible: hovered
                    ToolTip.text: modelData.tip
                    Accessible.name: modelData.tip
                    onToggled: PaletteModel[modelData.key] = checked
                }
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
                required property bool runnable
                required property bool current

                width: ListView.view.width
                implicitHeight: 34
                opacity: row.runnable ? 1 : 0.5
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
                        visible: row.current
                        text: qsTr("Current")
                        color: Theme.palette.color("textMuted", "#a1a1aa")
                        font.pixelSize: 11
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
