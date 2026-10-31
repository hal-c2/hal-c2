pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// The open deck of the Space view (Spaces.deck): its title, the way to present
// it, and its slides, each edited in place and written when the user leaves the
// field. A trashed deck is read only, with the way back.
Rectangle {
    id: deck

    objectName: "spaceDeck"

    readonly property var current: Spaces.deck
    readonly property bool trashed: current.trashed === true
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color lineColor: Theme.palette.color("border", "#27272a")

    function addSlide(afterSlideId) {
        const payload = { deckId: Spaces.deckId, title: "", body: "" };
        if (afterSlideId !== "")
            payload.afterSlideId = afterSlideId;
        Shell.dispatch("space.slide.insert", payload);
    }

    onCurrentChanged: {
        if (!titleField.activeFocus)
            titleField.text = current.title ?? "";
    }

    color: Theme.palette.color("canvas", "#09090b")

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: 48
        anchors.rightMargin: 48
        anchors.topMargin: 24
        spacing: 8

        Text {
            text: Spaces.spaceName
            color: deck.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            ShellButton {
                id: deckActions

                objectName: "spaceDeckActions"
                subtle: true
                iconName: "ellipsis"
                Accessible.name: qsTr("Deck actions")
                onClicked: actionsMenu.popup(deckActions, 0, deckActions.height + 4)
            }

            TextInput {
                id: titleField

                objectName: "spaceDeckTitle"
                Layout.fillWidth: true
                readOnly: deck.trashed
                color: deck.foreground
                selectByMouse: true
                selectionColor: Theme.palette.color("accent", "#2563eb")
                selectedTextColor: Theme.palette.color("accentForeground", "#ffffff")
                font.pixelSize: Math.round(28 * Theme.fontScale)
                font.weight: Font.Bold
                clip: true

                function commit() {
                    const title = text.trim();
                    if (title.length > 0 && title !== deck.current.title)
                        Shell.dispatch("space.deck.rename", { deckId: Spaces.deckId, title: title });
                    else
                        text = deck.current.title ?? "";
                }

                onAccepted: focus = false
                onActiveFocusChanged: {
                    if (!activeFocus)
                        commit();
                }
                Keys.onEscapePressed: {
                    text = deck.current.title ?? "";
                    focus = false;
                }
            }

            ShellButton {
                objectName: "spaceDeckPresent"
                primary: true
                iconName: "play"
                text: qsTr("Present")
                enabled: !deck.trashed && Spaces.slides.count > 0
                onClicked: Shell.dispatch("space.deck.present", { deckId: Spaces.deckId })
            }
        }

        ShellMenu {
            id: actionsMenu

            ShellMenuItem {
                objectName: "spaceDeckAddSlide"
                text: qsTr("Add a slide")
                iconName: "plus"
                enabled: !deck.trashed
                onTriggered: deck.addSlide("")
            }

            ShellMenuSeparator {}

            ShellMenuItem {
                text: deck.trashed ? qsTr("Restore") : qsTr("Move to the trash")
                iconName: deck.trashed ? "archive-restore" : "trash"
                destructive: !deck.trashed
                onTriggered: Shell.dispatch(deck.trashed ? "space.deck.restore" : "space.deck.trash", { deckId: Spaces.deckId })
            }
        }

        Rectangle {
            objectName: "spaceDeckTrashedBanner"
            Layout.fillWidth: true
            visible: deck.trashed
            implicitHeight: trashedRow.implicitHeight + 16
            radius: Math.min(Theme.radius, 8)
            color: Qt.alpha(Theme.palette.color("warning", "#f59e0b"), 0.12)
            border.color: Qt.alpha(Theme.palette.color("warning", "#f59e0b"), 0.4)

            RowLayout {
                id: trashedRow

                anchors.fill: parent
                anchors.margins: 8
                spacing: 8

                ShellIcon {
                    name: "trash"
                    size: 14
                    color: deck.foreground
                }

                Text {
                    Layout.fillWidth: true
                    text: qsTr("This deck is in the trash, so it cannot be changed.")
                    color: deck.foreground
                    wrapMode: Text.Wrap
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                }

                ShellButton {
                    objectName: "spaceDeckRestore"
                    text: qsTr("Restore")
                    iconName: "archive-restore"
                    onClicked: Shell.dispatch("space.deck.restore", { deckId: Spaces.deckId })
                }

                ShellButton {
                    objectName: "spaceDeckDelete"
                    text: qsTr("Delete for good")
                    tint: Theme.palette.color("error", "#ef4444")
                    onClicked: Shell.dispatch("space.deck.delete", { deckId: Spaces.deckId })
                }
            }
        }

        ListView {
            objectName: "spaceSlides"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 8
            model: Spaces.slides
            boundsBehavior: Flickable.StopAtBounds
            bottomMargin: 24

            delegate: Rectangle {
                id: card

                required property var model
                required property int index
                required property string title
                required property string body
                readonly property string slideId: model.id

                function writeTitle() {
                    if (slideTitle.text !== card.title && !deck.trashed)
                        Shell.dispatch("space.slide.update", { slideId: card.slideId, title: slideTitle.text });
                }

                function writeBody() {
                    if (slideBody.text !== card.body && !deck.trashed)
                        Shell.dispatch("space.slide.update", { slideId: card.slideId, body: slideBody.text });
                }

                objectName: "spaceSlide:" + index
                width: ListView.view.width
                height: cardRow.implicitHeight + 20
                radius: Math.min(Theme.radius, 8)
                color: "transparent"
                border.color: deck.lineColor

                // The fields follow the slide while the user is not writing in them.
                onTitleChanged: {
                    if (!slideTitle.activeFocus)
                        slideTitle.text = card.title;
                }
                onBodyChanged: {
                    if (!slideBody.activeFocus)
                        slideBody.text = card.body;
                }

                RowLayout {
                    id: cardRow

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 10
                    spacing: 10

                    Text {
                        Layout.alignment: Qt.AlignTop
                        text: String(card.index + 1)
                        color: deck.muted
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4

                        TextInput {
                            id: slideTitle

                            objectName: "spaceSlideTitle:" + card.index
                            Layout.fillWidth: true
                            text: card.title
                            readOnly: deck.trashed
                            color: deck.foreground
                            selectByMouse: true
                            clip: true
                            font.pixelSize: Math.round(16 * Theme.fontScale)
                            font.weight: Font.DemiBold
                            onAccepted: focus = false
                            onActiveFocusChanged: {
                                if (!activeFocus)
                                    card.writeTitle();
                            }
                            Keys.onEscapePressed: {
                                text = card.title;
                                focus = false;
                            }

                            Text {
                                visible: slideTitle.text === ""
                                text: qsTr("Slide title")
                                color: deck.muted
                                font: slideTitle.font
                            }
                        }

                        TextEdit {
                            id: slideBody

                            objectName: "spaceSlideBody:" + card.index
                            Layout.fillWidth: true
                            text: card.body
                            readOnly: deck.trashed
                            color: deck.foreground
                            textFormat: TextEdit.PlainText
                            wrapMode: TextEdit.Wrap
                            selectByMouse: true
                            font.pixelSize: Math.round(14 * Theme.fontScale)
                            onActiveFocusChanged: {
                                if (!activeFocus)
                                    card.writeBody();
                            }
                            Keys.onEscapePressed: {
                                text = card.body;
                                focus = false;
                            }

                            Text {
                                visible: slideBody.text === ""
                                text: qsTr("What the slide says")
                                color: deck.muted
                                font: slideBody.font
                            }
                        }
                    }

                    RowLayout {
                        Layout.alignment: Qt.AlignTop
                        visible: !deck.trashed
                        spacing: 2

                        ShellButton {
                            objectName: "spaceSlideUp:" + card.index
                            subtle: true
                            iconName: "arrow-up"
                            implicitHeight: 24
                            implicitWidth: 24
                            Accessible.name: qsTr("Move up")
                            enabled: card.index > 0
                            onClicked: Shell.dispatch("space.slide.move", {
                                slideId: card.slideId,
                                afterSlideId: card.index > 1 ? Spaces.slides.get(card.index - 2).id : ""
                            })
                        }

                        ShellButton {
                            objectName: "spaceSlideDown:" + card.index
                            subtle: true
                            iconName: "arrow-down"
                            implicitHeight: 24
                            implicitWidth: 24
                            Accessible.name: qsTr("Move down")
                            enabled: card.index + 1 < Spaces.slides.count
                            onClicked: Shell.dispatch("space.slide.move", { slideId: card.slideId, afterSlideId: Spaces.slides.get(card.index + 1).id })
                        }

                        ShellButton {
                            objectName: "spaceSlideAdd:" + card.index
                            subtle: true
                            iconName: "plus"
                            implicitHeight: 24
                            implicitWidth: 24
                            Accessible.name: qsTr("Add a slide below")
                            onClicked: deck.addSlide(card.slideId)
                        }

                        ShellButton {
                            objectName: "spaceSlideDelete:" + card.index
                            subtle: true
                            iconName: "trash"
                            implicitHeight: 24
                            implicitWidth: 24
                            tint: Theme.palette.color("error", "#ef4444")
                            Accessible.name: qsTr("Delete the slide")
                            onClicked: Shell.dispatch("space.slide.delete", { slideId: card.slideId })
                        }
                    }
                }
            }

            footer: Item {
                width: ListView.view ? ListView.view.width : 0
                height: deck.trashed ? 0 : 44

                ShellButton {
                    objectName: "spaceAddSlide"
                    anchors.bottom: parent.bottom
                    visible: !deck.trashed
                    subtle: true
                    iconName: "plus"
                    text: qsTr("Add a slide")
                    onClicked: deck.addSlide("")
                }
            }

            Text {
                objectName: "spaceDeckEmpty"
                anchors.top: parent.top
                visible: Spaces.slides.count === 0 && deck.trashed
                text: qsTr("This deck has no slides.")
                color: deck.muted
                font.pixelSize: Math.round(14 * Theme.fontScale)
            }
        }
    }
}
