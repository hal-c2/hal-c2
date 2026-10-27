pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The right panel's Files tab: the thread's workspace as the MC lists it,
// from a WorkspaceFiles (Panel.files). The tree loads a folder when it is
// expanded; typing searches the whole workspace. A file opens beside the
// tree, one row per line, to read, edit or copy whole; an image shows as
// itself, and other media open in the browser.
//
//   FilesPanel { anchors.fill: parent; source: Panel.files }
Rectangle {
    id: root

    property var source: null
    readonly property var tree: source?.tree ?? null
    readonly property string rootStatus: tree?.rootStatus ?? "loading"
    readonly property bool fileOpen: (source?.openPath ?? "").length > 0
    readonly property string mediaKind: source?.mediaKind ?? ""
    readonly property int maxLineColumns: 2000
    // Whether the tree shows beside an open file; with no file open it always shows.
    // Hiding it is a preference, kept while this panel lives (the next file opens
    // with the tree still hidden), not a state of the file that was open.
    property bool explorerOpen: true
    // What the tree takes beside an open file: at most 352px or 46% of the tab, and
    // never so much that the file (whose header buttons are its minimum width) is
    // pushed under it. A row layout does not shrink a fixed-size column on its own.
    readonly property real explorerShare: Math.max(0, Math.min(352, width * 0.46, width - 1 - fileViewer.Layout.minimumWidth))
    // Below this width the tree has no room for a row to be read, so a file that
    // leaves it less is open without the tree rather than beside a sliver of it that
    // still takes focus. A row needs its indent, icon and gap (8 + 13 + 6), about ten
    // characters of the name at the row's font (which follows the user's font scale,
    // so the floor does too), and a margin; 72 fixed px held six characters and a
    // search field of 26px. Longer names elide in the middle and say the rest in a
    // tooltip and the entry's accessible description.
    readonly property real explorerMinimum: Math.ceil(8 + 13 + 6 + rowSample.advanceWidth + 8)
    readonly property bool explorerShown: !fileOpen || (explorerOpen && explorerShare >= explorerMinimum)
    // True while keyboard focus sits inside the given item.
    function focusInside(item: Item): bool {
        let focused = root.Window.activeFocusItem;
        while (focused) {
            if (focused === item)
                return true;
            focused = focused.parent;
        }
        return false;
    }

    // When the explorer goes away under the focused item, focus would be
    // cleared to nowhere; give it to the toggle that brings the tree back.
    onExplorerShownChanged: {
        if (!explorerShown && fileOpen && focusInside(filesExplorerColumn))
            fileExplorerToggleButton.forceActiveFocus();
    }

    // The reverse case: closing the file hides the viewer holding the
    // toggle or close button, so give focus to the tree that remains.
    onFileOpenChanged: {
        if (!fileOpen && focusInside(fileViewer)) {
            // Without search (no workspace) the explorer holds nothing
            // focusable, so focus clearing to the window is intended.
            if (search.enabled)
                search.forceActiveFocus();
        }
    }

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color borderColor: Theme.palette.color("border", "#27272a")
    readonly property color errorColor: Theme.palette.color("errorForeground", "#ef4444")
    readonly property string mono: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"

    objectName: "filesPanel"
    color: Theme.palette.color("surface", "#0f0f11")

    // Ten ordinary characters at the tree row's font; sizes explorerMinimum.
    TextMetrics {
        id: rowSample

        font.pixelSize: Math.round(12 * Theme.fontScale)
        text: "abcdefghij"
    }

    TextMetrics {
        id: glyph

        font.family: root.mono
        font.pixelSize: Theme.fontSizeCode
        text: "M"
    }

    FileEntryMenu {
        id: entryMenu
    }

    // "Open in browser", once the address works.
    Connections {
        target: root.source
        function onMediaOpened(url) {
            Shell.openExternal(url);
        }
    }

    // The web's layout: the file takes the tab and the tree is a column beside it that
    // the file's header can hide. With no file open the tree is the whole tab.
    RowLayout {
        anchors.fill: parent
        spacing: 0

        ColumnLayout {
            id: fileViewer

            objectName: "fileViewer"
            // A file whose header is wider than the tab overflows this column;
            // clip here so the tree column does not pay for an offscreen pass.
            clip: true
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.fileOpen
            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 10
                Layout.rightMargin: 4
                Layout.preferredHeight: 30
                spacing: 4

                FilePathTrail {
                    Layout.fillWidth: true
                    // A long path gives way to the header's buttons (it clips)
                    // instead of widening the file past the tab.
                    Layout.minimumWidth: 0
                    clip: true
                    source: root.source
                }
                ShellButton {
                    objectName: "fileRender"
                    subtle: true
                    visible: (root.source?.renderKind ?? "").length > 0 && !(root.source?.editing ?? false)
                    text: root.source?.rendered ? qsTr("Source") : qsTr("Rendered")
                    implicitHeight: 26
                    onClicked: root.source.rendered = !root.source.rendered
                }
                ShellButton {
                    objectName: "fileEdit"
                    subtle: true
                    visible: root.source?.fileStatus === "ready" && root.mediaKind.length === 0
                    enabled: root.source?.editable ?? false
                    text: root.source?.editing ? qsTr("Done") : qsTr("Edit")
                    implicitHeight: 26
                    Accessible.description: root.source?.readOnlyReason ?? ""
                    onClicked: root.source.editing = !root.source.editing
                }
                ShellButton {
                    objectName: "fileCopy"
                    subtle: true
                    visible: root.source?.fileStatus === "ready" && root.mediaKind.length === 0
                    iconName: "copy"
                    iconSize: 13
                    iconTint: root.muted
                    implicitWidth: 26
                    implicitHeight: 26
                    Accessible.name: qsTr("Copy file contents")
                    onClicked: Shell.dispatch("files.copyContents", {})
                }
                ShellButton {
                    objectName: "fileOpenInEditor"
                    subtle: true
                    visible: (Shell.state.workspace?.editors ?? []).some(editor => editor.id !== "file-manager")
                    iconName: "external-link"
                    iconSize: 13
                    iconTint: root.muted
                    implicitWidth: 26
                    implicitHeight: 26
                    Accessible.name: qsTr("Open in editor")
                    onClicked: Shell.dispatch("files.openInEditor", {path: root.source.openPath})
                }
                ShellButton {
                    objectName: "fileWrap"
                    subtle: true
                    visible: root.mediaKind.length === 0
                    text: root.source?.wrap ? qsTr("No wrap") : qsTr("Wrap")
                    implicitHeight: 26
                    onClicked: root.source.wrap = !root.source.wrap
                }
                ShellButton {
                    id: fileExplorerToggleButton

                    objectName: "fileExplorerToggle"
                    subtle: true
                    // The button owns the flip; the panel copies it into the
                    // explorerOpen preference. checked presents what is on
                    // screen (explorerShown), so an auto-hidden tree does not
                    // read as shown, and the binding stays live for
                    // programmatic changes to the preference.
                    checkable: true
                    checked: root.explorerShown
                    // While the tab is too narrow for the tree the toggle
                    // cannot bring it back; it stays the focus home for the
                    // hidden column, and its tooltip says what will.
                    toolTip: root.fileOpen && root.explorerOpen && !root.explorerShown ? qsTr("Widen the panel to show the file explorer") : root.explorerShown ? qsTr("Hide file explorer") : qsTr("Show file explorer")
                    Accessible.description: toolTip
                    Accessible.checkable: true
                    Accessible.checked: checked
                    iconName: "folder-tree"
                    iconSize: 13
                    iconTint: root.muted
                    implicitWidth: 26
                    implicitHeight: 26
                    // Stable name: the checked state carries Hide/Show, so
                    // activation does not rename the focused button. The
                    // verb stays on the explicit tooltip above.
                    Accessible.name: qsTr("File explorer")
                    onClicked: {
                        root.explorerOpen = checked;
                        // Auto-hidden: explorerShown cannot follow the flip
                        // (and may not even re-notify), so snap checked back
                        // to what is on screen. This covers both entry
                        // states: shown-by-preference (preference kept, since
                        // checked flipped to true) and hidden-by-preference.
                        if (checked !== root.explorerShown)
                            checked = Qt.binding(() => root.explorerShown);
                    }
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
                color: Theme.palette.color("warningForeground", "#f59e0b")
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            Text {
                objectName: "fileNote"
                Layout.fillWidth: true
                Layout.leftMargin: 10
                Layout.rightMargin: 10
                Layout.bottomMargin: 4
                visible: text.length > 0
                // A failed save first; else why the file cannot be edited.
                text: (root.source?.saveProblem ?? "").length > 0 ? qsTr("Not saved: %1").arg(root.source.saveProblem) : (root.source?.unsaved ?? false) ? qsTr("Saving…") : root.source?.readOnlyReason ?? ""
                color: (root.source?.saveProblem ?? "").length > 0 ? root.errorColor : root.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                // The file rendered: Markdown (a CSV file as its table), or an HTML page's text and markup.
                Flickable {
                    id: renderedView

                    objectName: "fileRendered"
                    anchors.fill: parent
                    anchors.margins: 10
                    visible: (root.source?.rendered ?? false) && !root.source.fileEmpty
                    clip: true
                    contentHeight: (renderedBody.item as Item)?.implicitHeight ?? 0
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar {
                        Accessible.name: qsTr("Scroll rendered file")
                    }

                    Loader {
                        id: renderedBody

                        width: renderedView.width
                        active: renderedView.visible
                        sourceComponent: root.source?.renderKind === "html" ? renderedPage : renderedMarkdown
                    }
                    Component {
                        id: renderedMarkdown

                        Markdown {
                            objectName: "fileRenderedMarkdown"
                            // The file is the user's own, and its task boxes tick.
                            trusted: true
                            text: root.source?.renderedText ?? ""
                            onLinkActivated: link => {
                                if (link.startsWith("task:"))
                                    root.source.toggleTask(Number(link.slice(5)));
                                else
                                    Shell.openExternal(link);
                            }
                        }
                    }
                    Component {
                        id: renderedPage

                        Text {
                            id: renderedPageText

                            // A link opens on a Ctrl-click (Cmd on macOS) or a
                            // finger's tap, as in the rendered Markdown.
                            function follow(eventPoint) {
                                const link = linkAt(eventPoint.position.x, eventPoint.position.y);
                                if (link.length > 0)
                                    Shell.openExternal(link);
                            }

                            objectName: "fileRenderedPage"
                            text: root.source?.renderedText ?? ""
                            textFormat: Text.RichText
                            color: root.foreground
                            font.pixelSize: Math.round(13 * Theme.fontScale)
                            wrapMode: Text.Wrap

                            TapHandler {
                                acceptedButtons: Qt.LeftButton
                                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                                acceptedModifiers: Qt.ControlModifier
                                // ljos-allow(focus-pointer-only): a link in an HTML page's text; Qt's Text has no keyboard path between links, and the Source view shows each link to read and copy
                                onTapped: eventPoint => renderedPageText.follow(eventPoint)
                            }
                            TapHandler {
                                acceptedDevices: PointerDevice.TouchScreen
                                // ljos-allow(focus-pointer-only): a finger's tap on a link in an HTML page's text, as the Ctrl-click above
                                onTapped: eventPoint => renderedPageText.follow(eventPoint)
                            }
                            // The secondary button offers opening or copying the link.
                            TapHandler {
                                acceptedButtons: Qt.RightButton
                                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                                onTapped: eventPoint => {
                                    const link = renderedPageText.linkAt(eventPoint.position.x, eventPoint.position.y);
                                    if (link.length > 0) {
                                        Shell.dispatch("link.menu", {
                                            url: link,
                                            x: eventPoint.scenePosition.x,
                                            y: eventPoint.scenePosition.y
                                        });
                                    }
                                }
                            }
                        }
                    }
                }

                // The file as text the user changes; each change goes to the source, which writes it.
                ScrollView {
                    objectName: "fileEditorView"
                    anchors.fill: parent
                    visible: root.source?.editing ?? false

                    TextArea {
                        id: editor

                        objectName: "fileEditor"
                        color: root.foreground
                        font.family: root.mono
                        font.pixelSize: Theme.fontSizeCode
                        wrapMode: (root.source?.wrap ?? false) ? TextEdit.WrapAnywhere : TextEdit.NoWrap
                        textFormat: TextEdit.PlainText
                        selectByMouse: true
                        background: null
                        onTextChanged: if (root.source?.editing && text !== root.source.text) root.source.edit(text)

                        Connections {
                            target: root.source
                            function onRenderedChanged() {
                                if (root.source.editing && editor.text !== root.source.text) {
                                    editor.text = root.source.text;
                                    editor.forceActiveFocus();
                                }
                            }
                        }
                    }
                }

                // A media file, from the URL its environment signed. Only made
                // while the tab shows, so a hidden tab holds no media.
                Loader {
                    objectName: "fileMedia"
                    anchors.fill: parent
                    anchors.margins: 10
                    active: root.visible && root.source?.fileStatus === "ready" && root.mediaKind.length > 0
                    sourceComponent: root.mediaKind === "image" ? mediaImage : mediaElsewhere
                }
                Component {
                    id: mediaImage

                    Item {
                        Image {
                            id: image

                            objectName: "fileImage"
                            Accessible.name: (root.source?.openPath ?? "").split("/").pop()
                            anchors.centerIn: parent
                            width: Math.min(parent.width, implicitWidth)
                            height: Math.min(parent.height, implicitHeight)
                            source: root.source?.mediaUrl ?? ""
                            // A signed URL is not loaded twice: the next one is another URL.
                            cache: false
                            asynchronous: true
                            fillMode: Image.PreserveAspectFit
                            // Decoded no larger than a wide view needs, and never enlarged.
                            sourceSize: Qt.size(1440, 1440)
                            onStatusChanged: if (status === Image.Error)
                                root.source.mediaFailed(image.source)
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: image.status === Image.Loading
                            text: qsTr("Loading...")
                            color: root.muted
                            font.pixelSize: Math.round(13 * Theme.fontScale)
                        }
                    }
                }
                Component {
                    id: mediaElsewhere

                    ColumnLayout {
                        spacing: 10

                        Item {
                            Layout.fillHeight: true
                        }
                        Text {
                            objectName: "fileMediaNote"
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: root.mediaKind === "pdf" ? qsTr("This document can't be previewed here.") : root.mediaKind === "video" ? qsTr("This video can't be played here.") : qsTr("This audio can't be played here.")
                            color: root.muted
                            font.pixelSize: Math.round(13 * Theme.fontScale)
                            wrapMode: Text.Wrap
                        }
                        ShellButton {
                            objectName: "fileOpenMedia"
                            Layout.alignment: Qt.AlignHCenter
                            text: qsTr("Open in browser")
                            onClicked: root.source.openMedia()
                        }
                        Item {
                            Layout.fillHeight: true
                        }
                    }
                }

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
                        font.pixelSize: Math.round(13 * Theme.fontScale)
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
                    visible: root.source?.fileStatus === "ready" && root.mediaKind.length === 0 && !root.source.fileEmpty && !root.source.rendered && !root.source.editing
                    clip: true
                    model: root.source?.lines ?? null
                    reuseItems: true
                    boundsBehavior: Flickable.StopAtBounds
                    readonly property bool wrap: root.source?.wrap ?? false
                    readonly property real gutter: glyph.advanceWidth * 6 + 12
                    flickableDirection: wrap ? Flickable.VerticalFlick : Flickable.HorizontalAndVerticalFlick
                    contentWidth: wrap ? width : Math.max(width, gutter + glyph.advanceWidth * Math.min(model?.maxColumns ?? 0, root.maxLineColumns) + 16)
                    ScrollBar.vertical: ScrollBar {
                        Accessible.name: qsTr("Scroll file")
                    }
                    ScrollBar.horizontal: ScrollBar {
                        Accessible.name: qsTr("Scroll file sideways")
                    }

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
                            // ljos-allow(text-unbounded-dynamic): a line number, in a gutter six digits wide
                            text: line.number
                            color: root.muted
                            font.family: root.mono
                            font.pixelSize: Theme.fontSizeCode
                            topPadding: 2
                        }
                        Text {
                            id: body

                            x: lines.gutter
                            width: lines.wrap ? line.width - x - 8 : implicitWidth
                            text: line.text.length > root.maxLineColumns ? line.text.slice(0, root.maxLineColumns) + "…" : line.text
                            color: root.foreground
                            font.family: root.mono
                            font.pixelSize: Theme.fontSizeCode
                            textFormat: Text.PlainText
                            wrapMode: lines.wrap ? Text.WrapAnywhere : Text.NoWrap
                            topPadding: 1
                            bottomPadding: 1
                        }
                    }
                }
            }
        }

        Rectangle {
            Layout.fillHeight: true
            Layout.preferredWidth: 1
            visible: root.fileOpen && root.explorerShown
            color: root.borderColor
        }

        ColumnLayout {
            id: filesExplorerColumn

            objectName: "filesExplorer"
            Layout.fillHeight: true
            Layout.fillWidth: !root.fileOpen
            Layout.preferredWidth: root.fileOpen ? root.explorerShare : -1
            Layout.maximumWidth: root.fileOpen ? root.explorerShare : Infinity
            Layout.minimumWidth: 0
            visible: root.explorerShown
            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: 8
                spacing: 4

                ShellTextField {
                    id: search

                    objectName: "filesSearch"
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    placeholderText: qsTr("Search files")
                    Accessible.name: qsTr("Search files")
                    enabled: (root.source?.root ?? "").length > 0
                    text: root.source?.query ?? ""
                    onTextEdited: root.source.query = text
                    Keys.onEscapePressed: root.source.query = ""
                }
                ShellButton {
                    objectName: "filesExpandAll"
                    subtle: true
                    iconName: root.tree?.allExpanded ? "chevron-up" : "chevron-down"
                    iconSize: 13
                    iconTint: root.muted
                    implicitWidth: 26
                    implicitHeight: 26
                    enabled: root.rootStatus === "ready"
                    Accessible.name: root.tree?.allExpanded ? qsTr("Collapse all folders") : qsTr("Expand all folders")
                    onClicked: root.tree.allExpanded ? root.tree.collapseAll() : root.tree.expandAll()
                }
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
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
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
                        font.pixelSize: Math.round(13 * Theme.fontScale)
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
                    ScrollBar.vertical: ScrollBar {
                        Accessible.name: qsTr("Scroll file tree")
                    }

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
                        Accessible.description: path
                        ToolTip.visible: hovered && nameText.truncated
                        ToolTip.delay: 400
                        ToolTip.text: path
                        onClicked: {
                            if (kind === "directory")
                                root.tree.toggle(path);
                            else if (kind === "file")
                                root.source.openFile(path, 0);
                            else if (kind === "error")
                                root.tree.retry(path);
                        }
                        TapHandler {
                            acceptedButtons: Qt.RightButton
                            enabled: entry.kind === "file"
                            onTapped: {
                                entryMenu.path = entry.path;
                                entryMenu.popup(entry);
                            }
                        }
                        background: Rectangle {
                            color: entry.selected ? Theme.palette.color("sidebarRowSelected", "#25314d") : entry.hovered ? Theme.palette.color("surfaceRaised", "#1f1f24") : "transparent"
                            border.width: entry.visualFocus ? 1 : 0
                            border.color: Theme.palette.color("focus", "#3b82f6")
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
                                id: nameText

                                Layout.fillWidth: true
                                text: entry.kind === "loading" ? qsTr("Loading...") : entry.kind === "error" ? qsTr("%1 Click to retry.").arg(entry.problem) : entry.name
                                color: entry.kind === "error" ? root.errorColor : entry.ignored || entry.kind === "loading" ? root.muted : root.foreground
                                font.pixelSize: Math.round(12 * Theme.fontScale)
                                elide: Text.ElideMiddle
                            }
                        }
                    }
                }
            }
        }
    }
}
