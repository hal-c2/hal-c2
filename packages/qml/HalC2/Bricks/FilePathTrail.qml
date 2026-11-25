pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// The open file's path as a trail of its folders: a folder lists what is in
// it, folders first; picking a file opens it and picking a folder goes there.
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
        property Item anchor: null
        readonly property string status: trail.source?.trailStatus ?? ""
        readonly property string problem: trail.source?.trailProblem ?? ""
        // What is in the folder, then why there is nothing, and a retry if that may pass.
        readonly property var rows: {
            const entries = trail.source?.trailEntries ?? [];
            if (status === "loading")
                return [{message: qsTr("Loading…")}];
            if (entries.length > 0)
                return entries;
            return problem.length > 0 ? [{message: problem}].concat(status === "error" ? [{retry: true}] : []) : [];
        }

        function show(folder, anchor) {
            siblings.folder = folder;
            siblings.anchor = anchor;
            trail.source.listTrail(folder);
            popup(anchor, 0, anchor.height);
        }

        function reopen(folder) {
            Qt.callLater(() => siblings.show(folder, siblings.anchor));
        }

        objectName: "filePathSiblings"
        implicitWidth: 240

        Instantiator {
            model: siblings.rows

            delegate: ShellMenuItem {
                required property var modelData
                readonly property string path: modelData.path ?? ""
                readonly property string openPath: trail.source?.openPath ?? ""

                objectName: path.length > 0 ? "filePathSibling-" + path : modelData.retry ? "filePathRetry" : "filePathMessage"
                text: modelData.name ?? modelData.message ?? qsTr("Try again")
                enabled: path.length > 0 || modelData.retry === true
                iconName: path.length === 0 ? "" : modelData.directory ? "folder" : "file-text"
                current: path.length > 0 && (path === openPath || openPath.startsWith(path + "/"))
                onTriggered: {
                    if (modelData.retry)
                        siblings.reopen(siblings.folder);
                    else if (modelData.directory)
                        siblings.reopen(path);
                    else
                        Shell.dispatch("files.open", {path: path});
                }
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
                // A file outside the project has no folders of the project to list.
                enabled: !(trail.source?.outsideProject ?? false)
                checked: siblings.visible && siblings.anchor === this
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
