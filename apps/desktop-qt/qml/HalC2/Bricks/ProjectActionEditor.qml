import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Adds or edits one of the project's actions (`projectActions.editor`,
// ProjectActionsController): the controller holds the fields, checks them on
// save and says what is missing.
Dialog {
    id: dialog

    readonly property var editor: Shell.state.projectActions?.editor ?? null
    readonly property bool editing: (editor?.scriptId ?? "").length > 0
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property var icons: ["play", "test", "lint", "configure", "build", "debug"]

    function set(field, value) {
        const fields = {};
        fields[field] = value;
        Shell.dispatch("projectActions.set", fields);
    }

    objectName: "projectActionEditor"
    parent: Overlay.overlay
    modal: true
    anchors.centerIn: parent
    scale: Shell.state.layout?.zoom ?? 1
    transformOrigin: Item.TopLeft
    width: Math.min(480, (parent?.width ?? 512) / scale - 32)
    padding: 20
    closePolicy: Popup.CloseOnEscape
    title: editing ? qsTr("Edit action") : qsTr("Add action")
    onEditorChanged: editor !== null ? open() : close()
    onRejected: Shell.dispatch("projectActions.cancel")

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
        spacing: 8

        Caption {
            Layout.fillWidth: true
            text: qsTr("Actions are project-scoped commands you can run from the top bar or keybindings.")
        }
        Caption {
            text: qsTr("Name")
        }
        ShellTextField {
            objectName: "projectActionName"
            Layout.fillWidth: true
            placeholderText: qsTr("Test")
            text: dialog.editor?.name ?? ""
            onTextEdited: dialog.set("name", text)
        }
        Caption {
            text: qsTr("Command")
        }
        ShellTextField {
            objectName: "projectActionCommand"
            Layout.fillWidth: true
            placeholderText: qsTr("bun test")
            font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
            text: dialog.editor?.command ?? ""
            onTextEdited: dialog.set("command", text)
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            ColumnLayout {
                spacing: 8

                Caption {
                    text: qsTr("Icon")
                }
                ShellComboBox {
                    objectName: "projectActionIcon"
                    outline: true
                    model: dialog.icons
                    currentIndex: Math.max(0, dialog.icons.indexOf(dialog.editor?.icon ?? "play"))
                    onActivated: index => dialog.set("icon", dialog.icons[index])
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 8

                Caption {
                    text: qsTr("Keybinding")
                }
                ShellTextField {
                    objectName: "projectActionKeybinding"
                    Layout.fillWidth: true
                    placeholderText: qsTr("Press a shortcut, Backspace to clear")
                    readOnly: true
                    text: dialog.editor?.keybinding ?? ""
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab || event.key === Qt.Key_Escape)
                            return;
                        event.accepted = true;
                        if (event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete) {
                            dialog.set("keybinding", "");
                            return;
                        }
                        const recorded = Keybindings.recordKey(event.key, event.modifiers);
                        if (recorded.length > 0)
                            dialog.set("keybinding", recorded);
                    }
                }
            }
        }
        Caption {
            text: qsTr("Preview address")
        }
        ShellTextField {
            objectName: "projectActionPreviewUrl"
            Layout.fillWidth: true
            placeholderText: qsTr("http://localhost:3000")
            text: dialog.editor?.previewUrl ?? ""
            onTextEdited: dialog.set("previewUrl", text)
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Switch {
                objectName: "projectActionAutoOpenPreview"
                enabled: dialog.editor?.canAutoOpenPreview ?? false
                checked: dialog.editor?.autoOpenPreview ?? false
                onToggled: dialog.set("autoOpenPreview", checked)
            }
            Caption {
                Layout.fillWidth: true
                text: qsTr("Open the preview automatically when the action runs")
            }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Switch {
                objectName: "projectActionSetup"
                checked: dialog.editor?.runOnWorktreeCreate ?? false
                onToggled: dialog.set("runOnWorktreeCreate", checked)
            }
            Caption {
                Layout.fillWidth: true
                text: qsTr("Run automatically on worktree creation")
            }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Switch {
                objectName: "projectActionWait"
                enabled: dialog.editor?.runOnWorktreeCreate ?? false
                checked: dialog.editor?.waitForSetup ?? false
                onToggled: dialog.set("waitForSetup", checked)
            }
            Caption {
                Layout.fillWidth: true
                text: qsTr("Start the agent only after it finishes")
            }
        }
        Label {
            objectName: "projectActionError"
            Layout.fillWidth: true
            visible: text.length > 0
            text: dialog.editor?.error ?? ""
            color: Theme.palette.color("error", "#ef4444")
            font.pixelSize: Math.round(12 * Theme.fontScale)
            wrapMode: Text.Wrap
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 8
            spacing: 8

            ShellButton {
                objectName: "projectActionDelete"
                visible: dialog.editing
                text: qsTr("Delete")
                tint: Theme.palette.color("error", "#ef4444")
                onClicked: Shell.dispatch("projectActions.delete", {})
            }
            Item {
                Layout.fillWidth: true
            }
            ShellButton {
                objectName: "projectActionCancel"
                text: qsTr("Cancel")
                onClicked: dialog.reject()
            }
            ShellButton {
                objectName: "projectActionSave"
                primary: true
                enabled: !(dialog.editor?.saving ?? false)
                text: dialog.editing ? qsTr("Save changes") : qsTr("Save action")
                onClicked: Shell.dispatch("projectActions.save")
            }
        }
    }
}
