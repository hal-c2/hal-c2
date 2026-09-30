import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The right panel's Files tab: the thread's workspace as the node lists it,
// from a WorkspaceFiles (Panel.files). The tree loads a folder when it is
// expanded; typing searches the whole workspace. A file opens read-only
// below the tree, one row per line.
//
//   FilesPanel { anchors.fill: parent; source: Panel.files }
Rectangle {
    id: root

    property var source: null
    readonly property var tree: source?.tree ?? null
    readonly property string rootStatus: tree?.rootStatus ?? "loading"
    readonly property bool fileOpen: (source?.openPath ?? "").length > 0
    readonly property int maxLineColumns: 2000

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color border: Theme.palette.color("border", "#27272a")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
    readonly property string mono: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"

    objectName: "filesPanel"
    color: Theme.palette.color("surface", "#0f0f11")

    TextMetrics {
        id: glyph

        font.family: root.mono
        font.pixelSize: 12
        text: "M"
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ShellTextField {
            id: search

            objectName: "filesSearch"
            Layout.fillWidth: true
            Layout.margins: 8
            placeholderText: qsTr("Search files")
            enabled: (root.source?.root ?? "").length > 0
            text: root.source?.query ?? ""
            onTextEdited: root.source.query = text
            Keys.onEscapePressed: root.source.query = ""
        }

        Text {
            objectName: "filesSearchNote"
            Layout.fillWidth: true
            Layout.leftMargin: 10
            Layout.rightMargin: 10
            Layout.bottomMargin: 4
            visible: text.length > 0
            text: {
                if (!root.source || root.source.query.length === 0)
                    return "";
                if (root.source.searching)
                    return qsTr("Searching...");
                if (root.source.searchProblem.length > 0)
                    return root.source.searchProblem;
                if (treeView.count === 0)
                    return qsTr("No files match.");
                return root.source.searchTruncated ? qsTr("Showing the first matches; refine the search for more.") : "";
            }
            color: root.source?.searchProblem.length > 0 ? root.errorColor : root.muted
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredHeight: root.fileOpen ? 2 : 1
            Layout.minimumHeight: 80

            ColumnLayout {
                id: rootMessage

                objectName: "filesRootMessage"
                anchors.centerIn: parent
                width: parent.width - 32
                visible: root.rootStatus === "error" || (root.source?.root ?? "").length === 0
                spacing: 10

                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: (root.source?.root ?? "").length === 0 ? qsTr("This thread has no workspace.") : root.tree?.rootProblem ?? ""
                    color: root.rootStatus === "error" ? root.errorColor : root.muted
                    font.pixelSize: 13
                    wrapMode: Text.Wrap
                }
                ShellButton {
                    objectName: "filesRetry"
                    Layout.alignment: Qt.AlignHCenter
                    visible: root.rootStatus === "error"
                    text: qsTr("Try again")
                    onClicked: root.source.reload()
                }
            }

            ListView {
                id: treeView

                objectName: "filesTree"
                anchors.fill: parent
                visible: !rootMessage.visible
                clip: true
                model: root.tree
                reuseItems: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}

                Connections {
                    target: root.tree
                    function onSelectedChanged() {
                        const row = root.tree.rowOf(root.tree.selectedPath);
                        if (row >= 0)
                            treeView.positionViewAtIndex(row, ListView.Contain);
                    }
                }

                delegate: AbstractButton {
                    id: entry

                    required property string path
                    required property string name
                    required property int depth
                    required property string kind
                    required property bool expanded
                    required property bool ignored
                    required property string problem
                    required property bool selected

                    objectName: "filesEntry-" + (kind === "file" || kind === "directory" ? path : kind + "-" + path)
                    width: treeView.width
                    height: 24
                    hoverEnabled: true
                    leftPadding: 8 + depth * 14
                    Accessible.name: name
                    onClicked: {
                        if (kind === "directory")
                            root.tree.toggle(path);
                        else if (kind === "file")
                            root.source.openFile(path, 0);
                        else if (kind === "error")
                            root.tree.retry(path);
                    }
                    background: Rectangle {
                        color: entry.selected ? Theme.palette.color("sidebarRowSelected", "#25314d") : entry.hovered ? Theme.palette.color("surfaceRaised", "#1f1f24") : "transparent"
                    }
                    contentItem: RowLayout {
                        spacing: 6

                        ShellIcon {
                            visible: entry.kind === "directory" || entry.kind === "file"
                            name: entry.kind === "directory" ? (entry.expanded ? "folder-open" : "folder") : "file-text"
                            size: 13
                            color: root.muted
                        }
                        Text {
                            Layout.fillWidth: true
                            text: entry.kind === "loading" ? qsTr("Loading...") : entry.kind === "error" ? qsTr("%1 Click to retry.").arg(entry.problem) : entry.name
                            color: entry.kind === "error" ? root.errorColor : entry.ignored || entry.kind === "loading" ? root.muted : root.foreground
                            font.pixelSize: 12
                            elide: Text.ElideMiddle
                        }
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            visible: root.fileOpen
            color: root.border
        }

        ColumnLayout {
            objectName: "fileViewer"
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredHeight: 3
            visible: root.fileOpen
            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 10
                Layout.rightMargin: 4
                Layout.preferredHeight: 30
                spacing: 4

                Text {
                    Layout.fillWidth: true
                    text: root.source?.openPath ?? ""
                    color: root.foreground
                    font.family: root.mono
                    font.pixelSize: 12
                    elide: Text.ElideMiddle
                }
                ShellButton {
                    objectName: "fileWrap"
                    subtle: true
                    text: root.source?.wrap ? qsTr("No wrap") : qsTr("Wrap")
                    implicitHeight: 26
                    onClicked: root.source.wrap = !root.source.wrap
                }
                ShellButton {
                    objectName: "fileClose"
                    subtle: true
                    iconName: "x"
                    iconSize: 13
                    iconTint: root.muted
                    implicitWidth: 26
                    implicitHeight: 26
                    Accessible.name: qsTr("Close file")
                    onClicked: root.source.closeFile()
                }
            }

            Text {
                objectName: "fileTruncated"
                Layout.fillWidth: true
                Layout.leftMargin: 10
                Layout.rightMargin: 10
                Layout.bottomMargin: 4
                visible: text.length > 0
                text: root.source?.truncatedNotice ?? ""
                color: Theme.palette.color("warning", "#f59e0b")
                font.pixelSize: 12
                wrapMode: Text.Wrap
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                ColumnLayout {
                    objectName: "fileMessage"
                    anchors.centerIn: parent
                    width: parent.width - 32
                    visible: messageText.text.length > 0
                    spacing: 10

                    Text {
                        id: messageText

                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        text: {
                            const status = root.source?.fileStatus ?? "none";
                            if (status === "loading")
                                return qsTr("Loading...");
                            if (status === "error")
                                return root.source.fileProblem;
                            if (status === "ready" && root.source.fileEmpty)
                                return qsTr("This file is empty.");
                            return "";
                        }
                        color: root.source?.fileStatus === "error" ? root.errorColor : root.muted
                        font.pixelSize: 13
                        wrapMode: Text.Wrap
                    }
                    ShellButton {
                        objectName: "fileRetry"
                        Layout.alignment: Qt.AlignHCenter
                        visible: root.source?.fileStatus === "error"
                        text: qsTr("Try again")
                        onClicked: root.source.reloadFile()
                    }
                }

                ListView {
                    id: lines

                    objectName: "fileLines"
                    anchors.fill: parent
                    visible: root.source?.fileStatus === "ready" && !root.source.fileEmpty
                    clip: true
                    model: root.source?.lines ?? null
                    reuseItems: true
                    boundsBehavior: Flickable.StopAtBounds
                    readonly property bool wrap: root.source?.wrap ?? false
                    readonly property real gutter: glyph.advanceWidth * 6 + 12
                    flickableDirection: wrap ? Flickable.VerticalFlick : Flickable.HorizontalAndVerticalFlick
                    contentWidth: wrap ? width : Math.max(width, gutter + glyph.advanceWidth * Math.min(model?.maxColumns ?? 0, root.maxLineColumns) + 16)
                    ScrollBar.vertical: ScrollBar {}
                    ScrollBar.horizontal: ScrollBar {}

                    Connections {
                        target: root.source
                        function onRevealRequested() {
                            if (root.source.revealLine > 0)
                                Qt.callLater(() => lines.positionViewAtIndex(root.source.revealLine - 1, ListView.Center));
                        }
                    }

                    delegate: Item {
                        id: line

                        required property int number
                        required property string text

                        readonly property bool revealed: number === (root.source?.revealLine ?? 0)
                        width: lines.contentWidth
                        height: Math.max(18, body.implicitHeight)

                        Rectangle {
                            anchors.fill: parent
                            visible: line.revealed
                            color: Qt.alpha(Theme.palette.color("accent", "#3b82f6"), 0.15)
                        }
                        Text {
                            width: glyph.advanceWidth * 6
                            horizontalAlignment: Text.AlignRight
                            text: line.number
                            color: root.muted
                            font.family: root.mono
                            font.pixelSize: 11
                            topPadding: 2
                        }
                        Text {
                            id: body

                            x: lines.gutter
                            width: lines.wrap ? line.width - x - 8 : implicitWidth
                            text: line.text.length > root.maxLineColumns ? line.text.slice(0, root.maxLineColumns) + "…" : line.text
                            color: root.foreground
                            font.family: root.mono
                            font.pixelSize: 12
                            textFormat: Text.PlainText
                            wrapMode: lines.wrap ? Text.WrapAnywhere : Text.NoWrap
                            topPadding: 1
                            bottomPadding: 1
                        }
                    }
                }
            }
        }
    }
}
