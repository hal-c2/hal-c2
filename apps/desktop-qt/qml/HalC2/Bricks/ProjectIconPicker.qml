import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Chooses a project's icon (`projectIconPicker`, IdentityController): a
// symbol or a monogram in a colour, an emoji, or an image file of the project.
Dialog {
    id: dialog

    readonly property var picker: Shell.state.projectIconPicker ?? null
    readonly property string mode: picker?.mode ?? "lucide"
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property var modes: [
        {mode: "lucide", label: qsTr("Icons")},
        {mode: "emoji", label: qsTr("Emoji")},
        {mode: "monogram", label: qsTr("Monogram")},
        {mode: "image", label: qsTr("Image")}
    ]

    function set(field, value) {
        const fields = {};
        fields[field] = value;
        Shell.dispatch("projectIcon.set", fields);
    }

    objectName: "projectIconPicker"
    parent: Overlay.overlay
    modal: true
    anchors.centerIn: parent
    scale: Shell.state.layout?.zoom ?? 1
    transformOrigin: Item.TopLeft
    width: Math.min(512, (parent?.width ?? 544) / scale - 32)
    padding: 20
    closePolicy: Popup.CloseOnEscape
    title: qsTr("Choose project icon")
    onPickerChanged: picker !== null ? open() : close()
    onRejected: Shell.dispatch("projectIcon.cancel")

    component Caption: Label {
        color: dialog.muted
        font.pixelSize: Math.round(12 * Theme.fontScale)
        wrapMode: Text.Wrap
    }

    background: Rectangle {
        color: Theme.palette.color("surfaceOverlay", "#18181b")
        border.color: Theme.palette.color("border", "#27272a")
        radius: Math.min(Theme.radius, 16)
    }
    header: Label {
        text: dialog.title
        padding: 20
        bottomPadding: 4
        font.pixelSize: Math.round(17 * Theme.fontScale)
        font.weight: Font.DemiBold
        color: dialog.foreground
    }
    contentItem: ColumnLayout {
        spacing: 10

        Caption {
            Layout.fillWidth: true
            text: qsTr("Choose an icon, emoji, monogram or image for %1.").arg(dialog.picker?.name ?? "")
        }
        RowLayout {
            spacing: 4

            Repeater {
                model: dialog.modes

                delegate: ShellButton {
                    required property var modelData

                    objectName: "projectIconMode-" + modelData.mode
                    text: modelData.label
                    subtle: dialog.mode !== modelData.mode
                    onClicked: dialog.set("mode", modelData.mode)
                }
            }
        }

        Caption {
            visible: dialog.mode === "lucide" || dialog.mode === "monogram"
            text: qsTr("Color")
        }
        Flow {
            Layout.fillWidth: true
            visible: dialog.mode === "lucide" || dialog.mode === "monogram"
            spacing: 6

            Repeater {
                model: dialog.picker?.colors ?? []

                delegate: AbstractButton {
                    id: swatch

                    required property var modelData

                    objectName: "projectIconColor-" + modelData.name
                    implicitWidth: 22
                    implicitHeight: 22
                    Accessible.name: modelData.name
                    onClicked: dialog.set("color", modelData.name)
                    background: Rectangle {
                        radius: width / 2
                        color: swatch.modelData.tint
                        border.width: dialog.picker?.color === swatch.modelData.name ? 2 : 0
                        border.color: dialog.foreground
                    }
                }
            }
        }

        Flow {
            Layout.fillWidth: true
            visible: dialog.mode === "lucide"
            spacing: 4

            Repeater {
                model: dialog.picker?.symbols ?? []

                delegate: ShellButton {
                    required property string modelData

                    objectName: "projectIconSymbol-" + modelData
                    subtle: dialog.picker?.symbol !== modelData
                    iconName: modelData
                    iconTint: dialog.picker?.tint ?? dialog.foreground
                    Accessible.name: modelData
                    onClicked: dialog.set("symbol", modelData)
                }
            }
        }

        ShellTextField {
            objectName: "projectIconEmoji"
            Layout.fillWidth: true
            visible: dialog.mode === "emoji"
            placeholderText: qsTr("Emoji")
            text: dialog.picker?.emoji ?? ""
            onTextEdited: dialog.set("emoji", text)
        }

        RowLayout {
            Layout.fillWidth: true
            visible: dialog.mode === "monogram"
            spacing: 10

            ShellTextField {
                objectName: "projectIconLetters"
                Layout.preferredWidth: 96
                placeholderText: qsTr("AB")
                text: dialog.picker?.letters ?? ""
                onTextEdited: dialog.set("letters", text)
            }
            ProjectIcon {
                size: 28
                icon: ({kind: "monogram", text: (dialog.picker?.letters ?? "").toUpperCase(), tint: dialog.picker?.tint ?? ""})
            }
            Caption {
                Layout.fillWidth: true
                text: qsTr("One or two letters or numbers.")
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: dialog.mode === "image"
            spacing: 6

            ShellTextField {
                objectName: "projectIconSearch"
                Layout.fillWidth: true
                placeholderText: qsTr("Search image files…")
                text: dialog.picker?.query ?? ""
                onTextEdited: Shell.dispatch("projectIcon.search", {query: text})
            }
            Caption {
                visible: text.length > 0
                text: {
                    if (dialog.picker === null || dialog.picker.query.length === 0)
                        return qsTr("Type to search the project's image files.");
                    if (dialog.picker.searching)
                        return qsTr("Searching...");
                    return dialog.picker.images.length === 0 ? qsTr("No image files match.") : "";
                }
            }
            ListView {
                objectName: "projectIconImages"
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(contentHeight, 200)
                clip: true
                model: dialog.picker?.images ?? []
                boundsBehavior: Flickable.StopAtBounds

                delegate: ItemDelegate {
                    id: image

                    required property string modelData

                    objectName: "projectIconImage-" + modelData
                    width: ListView.view.width
                    implicitHeight: 28
                    onClicked: Shell.dispatch("projectIcon.image", {path: modelData})
                    background: Rectangle {
                        radius: 6
                        color: image.hovered ? Theme.palette.color("surfaceRaised", "#1f1f24") : "transparent"
                    }
                    contentItem: Text {
                        text: image.modelData
                        color: dialog.foreground
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        elide: Text.ElideMiddle
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }

        Label {
            objectName: "projectIconError"
            Layout.fillWidth: true
            visible: text.length > 0
            text: dialog.picker?.error ?? ""
            color: Theme.palette.color("error", "#ef4444")
            font.pixelSize: Math.round(12 * Theme.fontScale)
            wrapMode: Text.Wrap
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 8
            spacing: 8

            Item {
                Layout.fillWidth: true
            }
            ShellButton {
                objectName: "projectIconCancel"
                text: qsTr("Cancel")
                onClicked: dialog.reject()
            }
            ShellButton {
                objectName: "projectIconSave"
                primary: true
                visible: dialog.mode !== "image"
                text: qsTr("Use icon")
                onClicked: Shell.dispatch("projectIcon.save")
            }
        }
    }
}
