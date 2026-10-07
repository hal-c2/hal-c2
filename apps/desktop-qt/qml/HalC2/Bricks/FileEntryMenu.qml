pragma ComponentBehavior: Bound
import QtQuick
import HalC2.Shell

// What a file's entry in the Files tab offers (FileActionsController).
ShellMenu {
    id: menu

    // Relative to the thread's workspace.
    property string path: ""
    readonly property var editors: Shell.state.workspace?.editors ?? []

    objectName: "fileEntryMenu"
    implicitWidth: 230

    ShellMenuItem {
        objectName: "fileEntryOpen"
        text: qsTr("Open")
        onTriggered: Shell.dispatch("files.open", {path: menu.path})
    }
    ShellMenuItem {
        objectName: "fileEntryReveal"
        text: qsTr("Reveal in file manager")
        enabled: menu.editors.some(editor => editor.id === "file-manager")
        onTriggered: Shell.dispatch("files.reveal", {path: menu.path})
    }
    Repeater {
        model: menu.editors.filter(editor => editor.id !== "file-manager")

        ShellMenuItem {
            required property var modelData

            objectName: "fileEntryEditor-" + modelData.id
            text: qsTr("Open in %1").arg(modelData.label)
            onTriggered: Shell.dispatch("files.openInEditor", {path: menu.path, editorId: modelData.id})
        }
    }
    ShellMenuItem {
        objectName: "fileEntryCopyMention"
        text: qsTr("Copy mention")
        onTriggered: Shell.dispatch("files.copyMention", {path: menu.path})
    }
    ShellMenuItem {
        objectName: "fileEntryAddToChat"
        text: qsTr("Add to chat")
        onTriggered: Shell.dispatch("files.addToChat", {path: menu.path})
    }
}
