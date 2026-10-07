pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// The open file's path as a trail of its folders: a folder lists the files
// beside it in the trail, and picking one opens it.
//
//   FilePathTrail { source: Panel.files }
RowLayout {
    id: trail

    property var source: null
    readonly property var parts: (source?.openPath ?? "").split("/").filter(part => part.length > 0)
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property string mono: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"

    // The folder the trail's `index`th part is ("" for the workspace itself).
    function folderAt(index) {
        return parts.slice(0, index + 1).join("/");
    }

    objectName: "filePathTrail"
    spacing: 2

    ShellMenu {
        id: siblings

        property string folder: ""
        // Read when the menu opens: the tree has loaded the folders of an open file.
        property var files: []

        function show(folder, anchor) {
            siblings.folder = folder;
            files = (trail.source?.tree?.entriesIn(folder) ?? []).filter(entry => !entry.directory);
            popup(anchor, 0, anchor.height);
        }

        objectName: "filePathSiblings"
        implicitWidth: 240

        Instantiator {
            model: siblings.files

            delegate: ShellMenuItem {
                required property var modelData

                objectName: "filePathSibling-" + modelData.path
                text: modelData.name
                iconName: "file-text"
                current: modelData.path === (trail.source?.openPath ?? "")
                onTriggered: Shell.dispatch("files.open", {path: modelData.path})
            }

            onObjectAdded: (index, object) => siblings.insertItem(index, object)
            onObjectRemoved: (index, object) => siblings.removeItem(object)
        }
    }

    Repeater {
        model: trail.parts

        delegate: RowLayout {
            id: part

            required property string modelData
            required property int index
            readonly property bool last: index === trail.parts.length - 1

            spacing: 2

            ShellButton {
                objectName: "filePathPart-" + trail.folderAt(part.index)
                subtle: true
                implicitHeight: 24
                text: part.modelData
                font.family: trail.mono
                font.pixelSize: Theme.fontSizeCode
                // A folder lists its files; the file itself, those beside it.
                Accessible.name: part.last ? qsTr("Files beside %1").arg(part.modelData) : qsTr("Files in %1").arg(part.modelData)
                onClicked: siblings.show(part.last ? trail.folderAt(part.index - 1) : trail.folderAt(part.index), this)
            }
            Text {
                visible: !part.last
                text: "/"
                color: trail.muted
                font.family: trail.mono
                font.pixelSize: Theme.fontSizeCode
            }
        }
    }
    Item {
        Layout.fillWidth: true
    }
}
