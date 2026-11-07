pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The right panel's Diff tab: what a thread's turns changed, from a
// ThreadDiff (Panel.diff). A picker chooses the latest turn, all changes or
// one turn; the patch is a DiffModel drawn one row per line, so a large diff
// only makes the rows in view. Reverting to the turn shown asks first (RevertDialog).
// The picker also offers the checkout itself: its working tree, or the branch
// against a base the user picks from the checkout's refs or names. The changed
// files can be listed as a tree that jumps to a file, and a file opens in the
// user's editor or the environment's file manager. A review cut short lists its
// files and loads each one's changes when it is opened.
//
// A source without turns (`hasTurns: false`, a pull request's code) shows no
// picker or whitespace option; one with setViewed(path, viewed) and
// `viewedPaths` gives each file a Viewed box.
//
//   DiffPanel { anchors.fill: parent; source: Panel.diff }
Rectangle {
    id: root

    property var source: null
    readonly property var model: source?.model ?? null
    readonly property string status: source?.status ?? "idle"
    // Whether lines wrap: as the setting says, except where a line of code
    // has less room than `wrapFloor` (a sheet in a narrow window, a split
    // half). Wrapped there, nearly every line would break mid-token, so the
    // code scrolls sideways under its pinned numbers instead.
    readonly property bool wantsWrap: source?.wrap ?? false
    readonly property bool wrap: wantsWrap && codeWidth >= wrapFloor
    readonly property real wrapFloor: glyph.advanceWidth * 40
    // The room one line of code has.
    readonly property real codeWidth: split ? (view.width - glyph.advanceWidth * 12) / 2 - Theme.space.sm : view.width - view.gutter - Theme.space.sm
    // Whether the lines scroll sideways: then a thin bar along the bottom
    // shows it, and each row keeps an end padding pinned to the right edge.
    readonly property bool sideways: !wrap && view.contentWidth > view.width + 0.5
    readonly property bool split: model?.split ?? false
    // One file of the selection is shown alone (ThreadDiff.focusPath).
    readonly property bool focused: (source?.focusPath ?? "").length > 0
    // Lines can be commented on for the prompt (a thread's diff; a pull
    // request's code has the host's own review).
    readonly property bool canComment: source?.reviewing !== undefined
    // A tap on a stacked line comments on it, for a screen with no pointer
    // to show the line's own button (the phone's).
    property bool touchLines: false
    // The branch is what is reviewed, against `source.comparedBase`.
    readonly property bool comparing: (source?.reviewing ?? false) && source.selection === -3
    // Whether the changed files are listed as a tree beside the diff.
    property bool showTree: false
    // Bumped when the files or the tree's open folders change.
    property int treeRevision: 0
    readonly property var tree: treeRevision >= 0 && showTree && model !== null && status === "ready" && model.fileCount > 0 ? model.tree() : []

    Connections {
        target: root.model
        function onPatchChanged() {
            root.treeRevision++;
        }
        function onTreeChanged() {
            root.treeRevision++;
        }
    }

    // A diff path as the thread's workspace has it, or "" outside it; a pull
    // request's paths are its own.
    function workspacePath(path) {
        return typeof root.source?.workspacePath === "function" ? root.source.workspacePath(path) : path;
    }
    // What the environment opens files with.
    readonly property var editors: Shell.state.workspace?.editors ?? []
    readonly property bool hasFileManager: editors.some(editor => editor.id === "file-manager")

    // Opens `file` and brings it to the top.
    function jumpTo(file) {
        root.model.setExpanded(file, true);
        view.positionViewAtIndex(root.model.rowOfFile(file), ListView.Beginning);
    }
    // Characters drawn of one line; the rest of a minified line is cut.
    readonly property int maxLineColumns: 2000

    readonly property color foreground: Theme.palette.color("ink", "#f2f3f5")
    readonly property color muted: Theme.palette.color("inkTertiary", "#8b919e")
    readonly property color borderColor: Theme.palette.color("border", "#27272a")
    readonly property color added: Theme.palette.color("diffAdded", "#22c55e")
    readonly property color removed: Theme.palette.color("diffRemoved", "#ef4444")
    // Line backgrounds: opaque, so a selection or hover over them reads the same in every theme.
    readonly property color addedSurface: Theme.palette.color("diffAddedSurface", Qt.alpha(added, 0.12))
    readonly property color removedSurface: Theme.palette.color("diffRemovedSurface", Qt.alpha(removed, 0.12))
    readonly property string mono: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"

    objectName: "diffPanel"
    color: Theme.palette.color("surface", "#0f0f11")

    function lineText(text) {
        return text.length > maxLineColumns ? text.slice(0, maxLineColumns) + "…" : text;
    }

    // Where a wrapped line's rest hangs: under its own indentation, at most
    // half the line's room, so a wrap never reads as a new statement at the
    // margin. Text keeps QTextOption's tab stop (80px).
    function indent(text) {
        const lead = /^[ \t]*/.exec(text)[0];
        const tabs = lead.split("\t").length - 1;
        return tabs * 80 + (lead.length - tabs) * glyph.advanceWidth;
    }

    TextMetrics {
        id: glyph

        font.family: root.mono
        font.pixelSize: Theme.fontSizeCode
        text: "M"
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.margins: Theme.space.sm
            spacing: Theme.space.sm

            ShellComboBox {
                id: picker

                objectName: "diffTurnPicker"
                Accessible.name: qsTr("Turn to show")
                Layout.preferredWidth: 6 * Theme.space.xl
                visible: root.source?.hasTurns ?? true
                outline: true
                model: root.source?.choices ?? []
                textRole: "label"
                valueRole: "value"
                enabled: count > 0
                // Found in the choices themselves, not with indexOfValue, so the index
                // follows them: a selection can land before the turns that list it do.
                currentIndex: {
                    const selection = root.source?.selection ?? -1;
                    return Math.max(0, (root.source?.choices ?? []).findIndex(choice => choice.value === selection));
                }
                onActivated: index => root.source.select(valueAt(index))
            }

            Text {
                Layout.fillWidth: true
                visible: root.status === "ready"
                text: {
                    const count = root.focused ? root.source.fileTotal : (root.model?.fileCount ?? 0);
                    if (root.focused)
                        return count === 1 ? qsTr("1 of %n file", "", count) : qsTr("1 of %n files", "", count);
                    return count === 1 ? qsTr("%n file", "", count) : qsTr("%n files", "", count);
                }
                color: root.muted
                font.pixelSize: Theme.type.meta.size
                elide: Text.ElideRight
            }
            Item {
                Layout.fillWidth: true
                visible: root.status !== "ready"
            }
            Text {
                visible: root.status === "ready"
                text: "+" + (root.model?.additions ?? 0)
                color: root.added
                font.pixelSize: Theme.type.meta.size
                font.features: { "tnum": 1 }
            }
            Text {
                visible: root.status === "ready"
                text: "−" + (root.model?.deletions ?? 0)
                color: root.removed
                font.pixelSize: Theme.type.meta.size
                font.features: { "tnum": 1 }
            }

            ShellButton {
                objectName: "diffShowAllFiles"
                visible: root.focused && root.status === "ready"
                subtle: true
                implicitHeight: Theme.control.md
                text: qsTr("Show all files")
                onClicked: root.source.showAllFiles()
            }

            ShellButton {
                objectName: "diffRevert"
                subtle: true
                iconName: "undo-2"
                iconSize: Theme.icon.md
                iconTint: root.muted
                implicitWidth: Theme.control.md
                implicitHeight: Theme.control.md
                enabled: root.source?.canRevert ?? false
                visible: (root.source?.latestTurn ?? 0) > 0
                Accessible.name: qsTr("Revert to this turn")
                ToolTip.visible: hovered
                ToolTip.text: root.source?.reverting ? qsTr("Reverting...") : qsTr("Revert to this turn")
                onClicked: confirm.ask(0)
            }

            ShellButton {
                objectName: "diffOptions"
                subtle: true
                iconName: "ellipsis"
                iconSize: Theme.icon.md
                iconTint: root.muted
                implicitWidth: Theme.control.md
                implicitHeight: Theme.control.md
                Accessible.name: qsTr("Diff options")
                onClicked: options.open()

                ShellMenu {
                    id: options

                    y: parent.height

                    ShellMenuItem {
                        objectName: "diffSplit"
                        text: root.split ? qsTr("Stacked view") : qsTr("Split view")
                        onTriggered: root.model.split = !root.split
                    }
                    ShellMenuItem {
                        objectName: "diffWrap"
                        text: root.wantsWrap ? qsTr("Don't wrap lines") : qsTr("Wrap lines")
                        // On, but too narrow here: says why the lines scroll.
                        detail: root.wantsWrap && !root.wrap ? qsTr("Too narrow here") : ""
                        onTriggered: root.source.wrap = !root.wantsWrap
                    }
                    ShellMenuItem {
                        objectName: "diffWhitespace"
                        visible: root.source?.ignoreWhitespace !== undefined
                        height: visible ? implicitHeight : 0
                        text: root.source?.ignoreWhitespace ? qsTr("Show whitespace changes") : qsTr("Hide whitespace changes")
                        onTriggered: root.source.ignoreWhitespace = !root.source.ignoreWhitespace
                    }
                    ShellMenuItem {
                        objectName: "diffExpandAll"
                        text: root.model?.allExpanded ? qsTr("Collapse all files") : qsTr("Expand all files")
                        enabled: (root.model?.fileCount ?? 0) > 0
                        onTriggered: root.model.allExpanded ? root.model.collapseAll() : root.model.expandAll()
                    }
                    ShellMenuItem {
                        objectName: "diffTree"
                        text: root.showTree ? qsTr("Hide file tree") : qsTr("Show file tree")
                        onTriggered: root.showTree = !root.showTree
                    }
                    ShellMenuItem {
                        objectName: "diffReload"
                        text: qsTr("Reload")
                        onTriggered: root.source.reload()
                    }
                }
            }
        }

        // What the branch is compared against, and a way to name another ref.
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space.sm
            Layout.rightMargin: Theme.space.sm
            Layout.bottomMargin: Theme.space.sm
            visible: root.comparing
            spacing: Theme.space.sm

            Text {
                text: qsTr("%1 against").arg(root.source?.comparedHead || qsTr("HEAD"))
                color: root.muted
                font.pixelSize: Theme.type.meta.size
                elide: Text.ElideMiddle
            }
            ShellButton {
                id: basePicker

                objectName: "diffBasePicker"
                Layout.fillWidth: true
                implicitHeight: Theme.control.md
                chevron: true
                text: (root.source?.baseRef ?? "").length > 0 ? root.source.baseRef : qsTr("Automatic")
                Accessible.name: qsTr("Compare against")
                ToolTip.visible: hovered && (root.source?.comparedBase ?? "").length > 0
                ToolTip.text: qsTr("Compared against %1").arg(root.source?.comparedBase ?? "")
                onClicked: bases.open()

                Popup {
                    id: bases

                    objectName: "diffBases"
                    y: parent.height + Theme.space.xs
                    width: Math.max(parent.width, 8 * Theme.space.xl)
                    padding: Theme.space.sm
                    onOpened: {
                        root.source.baseQuery = "";
                        root.source.loadBases();
                        baseSearch.text = "";
                        baseSearch.forceActiveFocus();
                    }
                    background: ShellPopoverSurface {}

                    contentItem: ColumnLayout {
                        spacing: Theme.space.xs

                        ShellTextField {
                            id: baseSearch

                            objectName: "diffBaseRef"
                            Layout.fillWidth: true
                            implicitHeight: Theme.control.md
                            placeholderText: qsTr("Search or type a ref")
                            Accessible.name: qsTr("Search refs to compare against")
                            onTextEdited: root.source.baseQuery = text
                            onAccepted: {
                                root.source.chooseTypedBase(text);
                                bases.close();
                            }
                        }
                        ListView {
                            id: baseList

                            objectName: "diffBaseChoices"
                            Layout.fillWidth: true
                            Layout.preferredHeight: Math.min(contentHeight, 10 * Theme.control.sm)
                            clip: true
                            model: root.source?.baseChoices ?? []
                            boundsBehavior: Flickable.StopAtBounds
                            delegate: ItemDelegate {
                                id: choice

                                required property var modelData

                                objectName: "diffBaseChoice-" + choice.modelData.label
                                width: baseList.width
                                height: Theme.control.md
                                padding: 0
                                leftPadding: Theme.space.sm
                                Accessible.name: choice.modelData.label
                                onClicked: {
                                    root.source.chooseBase(choice.modelData.id);
                                    bases.close();
                                }
                                background: Rectangle {
                                    color: choice.hovered ? Theme.palette.color("surfaceRaised", "#1f1f24") : "transparent"
                                }
                                contentItem: RowLayout {
                                    spacing: Theme.space.sm

                                    Text {
                                        Layout.fillWidth: true
                                        text: choice.modelData.label
                                        color: root.foreground
                                        font.pixelSize: Theme.type.meta.size
                                        elide: Text.ElideMiddle
                                    }
                                    Text {
                                        objectName: "diffBaseRemoteOnly"
                                        visible: choice.modelData.remoteOnly
                                        text: qsTr("Remote only")
                                        color: root.muted
                                        font.pixelSize: Theme.type.caption.size
                                    }
                                }
                            }
                        }
                        Text {
                            objectName: "diffBaseEmpty"
                            Layout.fillWidth: true
                            Layout.margins: Theme.space.sm
                            visible: baseList.count === 0
                            text: root.source?.basesLoading ? qsTr("Loading refs…") : qsTr("No matching refs.")
                            color: root.muted
                            font.pixelSize: Theme.type.meta.size
                        }
                    }
                }
            }
        }

        // The MC cut the patch short; what is listed still counts every change.
        Text {
            objectName: "diffTruncated"
            Layout.fillWidth: true
            Layout.leftMargin: Theme.space.sm
            Layout.rightMargin: Theme.space.sm
            Layout.bottomMargin: Theme.space.sm
            visible: (root.source?.truncated ?? false) && root.status === "ready"
            text: qsTr("This preview exceeds the size limit. Changes shown are incomplete. Totals include all changes.")
            color: root.muted
            font.pixelSize: Theme.type.meta.size
            wrapMode: Text.Wrap
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: root.borderColor
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            ListView {
                id: treeView

                objectName: "diffTreeRows"
                Layout.preferredWidth: Math.min(10 * Theme.control.sm, root.width * 0.35)
                Layout.fillHeight: true
                visible: root.tree.length > 0
                clip: true
                model: root.tree.filter(node => node.shown)
                boundsBehavior: Flickable.StopAtBounds
                delegate: ItemDelegate {
                    id: node

                    required property var modelData

                    objectName: "diffTreeNode"
                    width: treeView.width
                    height: Theme.control.sm
                    padding: 0
                    leftPadding: Theme.space.sm + node.modelData.depth * Theme.space.md
                    Accessible.name: node.modelData.path
                    onClicked: node.modelData.kind === "folder" ? root.model.toggleFolder(node.modelData.path) : root.jumpTo(node.modelData.file)
                    background: Rectangle {
                        color: node.hovered ? Theme.palette.color("surfaceRaised", "#1f1f24") : "transparent"
                    }
                    contentItem: RowLayout {
                        spacing: Theme.space.sm

                        ShellIcon {
                            name: node.modelData.kind === "file" ? "file" : node.modelData.open ? "folder-open" : "folder"
                            size: Theme.icon.sm
                            color: root.muted
                        }
                        Text {
                            Layout.fillWidth: true
                            text: node.modelData.name
                            color: node.modelData.kind === "folder" ? root.muted : root.foreground
                            font.pixelSize: Theme.type.meta.size
                            elide: Text.ElideMiddle
                        }
                    }
                }
            }
            Rectangle {
                Layout.preferredWidth: 1
                Layout.fillHeight: true
                visible: treeView.visible
                color: root.borderColor
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                // Loading, nothing to show or a failure share one geometry;
                // the description is the source's own reason.
                ShellEmptyState {
                    objectName: "diffMessage"
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, parent.width - 2 * Theme.space.xl)
                    visible: root.status !== "ready" && root.status !== "idle"
                    iconName: root.status === "error" ? "circle-alert" : root.status === "loading" ? "circle-dashed" : "file-diff"
                    // A turn with nothing to show names the turn, and offers the
                    // whole thread's changes.
                    readonly property int selection: root.source?.selection ?? 0
                    readonly property string scope: selection === -1 ? qsTr("the latest turn") : selection > 0 ? qsTr("turn %1").arg(selection) : ""
                    readonly property bool offersAll: root.status === "empty" && (selection === -1 || selection > 0)
                    title: root.status === "error" ? qsTr("Couldn't load the diff") : root.status === "loading" ? qsTr("Loading changes") : scope.length > 0 ? qsTr("No changes in %1").arg(scope) : qsTr("No changes")
                    description: root.status === "loading" ? "" : root.source?.message ?? ""
                    actionText: root.status === "error" ? qsTr("Try again") : offersAll ? qsTr("Show all changes") : ""
                    onActionTriggered: root.status === "error" ? root.source.reload() : root.source.select(0)
                }

                ListView {
                    id: view

                    objectName: "diffRows"
                    anchors.fill: parent
                    visible: root.status === "ready"
                    clip: true
                    model: root.model
                    reuseItems: true
                    boundsBehavior: Flickable.StopAtBounds
                    flickableDirection: root.wrap ? Flickable.VerticalFlick : Flickable.HorizontalAndVerticalFlick
                    // Unwrapped rows are as wide as the longest line, and scroll sideways together.
                    contentWidth: root.wrap ? width : Math.max(width, rowWidth)
                    // A stacked line: the comment button, both line numbers, the sign, the text.
                    readonly property real commentInset: root.canComment ? Theme.icon.md + Theme.space.xs : 0
                    readonly property real numbersWidth: glyph.advanceWidth * 10 + Theme.space.sm
                    readonly property real gutter: commentInset + numbersWidth + Theme.space.sm + glyph.advanceWidth * 2
                    readonly property real rowWidth: gutter + glyph.advanceWidth * Math.min(root.model?.maxColumns ?? 0, root.maxLineColumns) * (root.split ? 2 : 1) + Theme.space.xl
                    ScrollBar.vertical: ScrollBar {
                        Accessible.name: qsTr("Scroll diff")
                    }
                    // Still and always there while the lines scroll sideways,
                    // under the last row rather than over it.
                    bottomMargin: root.sideways ? sidewaysBar.height : 0
                    ScrollBar.horizontal: ScrollBar {
                        id: sidewaysBar
                        objectName: "diffSidewaysBar"
                        Accessible.name: qsTr("Scroll diff sideways")
                        policy: root.sideways ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                        padding: Theme.space.xxs
                        contentItem: Rectangle {
                            implicitHeight: Theme.space.xs
                            radius: Theme.radiusPill
                            color: Theme.palette.color("borderStrong", "#343a44")
                        }
                        background: Item {}
                    }

                    Connections {
                        target: root.source
                        function onRevealRow(row) {
                            view.positionViewAtIndex(row, ListView.Beginning);
                        }
                    }

                    delegate: Loader {
                        id: row

                        required property int index
                        required property string kind
                        required property int file
                        required property string path
                        required property string previousPath
                        required property string change
                        required property bool binary
                        required property int additions
                        required property int deletions
                        required property bool expanded
                        required property string text
                        required property string sign
                        required property var oldLine
                        required property var newLine
                        required property string rightText
                        required property string rightSign
                        required property string state
                        required property string note
                        required property bool partial

                        width: view.contentWidth
                        sourceComponent: kind === "file" ? fileHeader : kind === "hunk" ? hunkHeader : root.split ? splitLine : stackedLine
                    }
                }
            }
        }
    }

    Component {
        id: fileHeader

        AbstractButton {
            id: header

            readonly property var row: parent
            // Listed without its changes, and opened: why they are not shown.
            readonly property bool waiting: row.expanded && row.state.length > 0
            readonly property string inWorkspace: root.workspacePath(row.path)
            objectName: "diffFile-" + row.path
            height: waiting ? 2 * Theme.control.lg - Theme.space.xs : Theme.control.lg
            hoverEnabled: true
            // The header's text stays in view while the lines scroll sideways.
            leftPadding: Math.max(0, view.contentX - view.originX)
            rightPadding: Math.max(0, width - leftPadding - view.width)
            Accessible.name: row.path
            onClicked: root.model.toggle(row.file)
            background: Rectangle {
                color: header.hovered ? Theme.palette.color("surfaceOverlay", "#1f1f24") : Theme.palette.color("surfaceRaised", "#16181c")
                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: 1
                    color: root.borderColor
                }
            }
            contentItem: ColumnLayout {
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.control.lg
                    spacing: Theme.space.sm

                    ShellChevron {
                        Layout.leftMargin: Theme.space.sm
                        direction: header.row.expanded ? "down" : "right"
                        size: Theme.icon.sm
                        color: root.muted
                    }
                    Text {
                        Layout.fillWidth: true
                        text: header.row.previousPath.length > 0 ? header.row.previousPath + " → " + header.row.path : header.row.path
                        color: header.row.change === "deleted" ? root.muted : root.foreground
                        font.family: root.mono
                        font.pixelSize: Theme.fontSizeCode
                        font.strikeout: header.row.change === "deleted"
                        elide: Text.ElideMiddle
                    }
                    Text {
                        objectName: "diffFilePartial"
                        visible: header.row.partial
                        text: qsTr("Partial diff preview")
                        color: root.muted
                        font.pixelSize: Theme.type.caption.size
                        ToolTip.text: qsTr("This file is too large to show in full. Counts include all changes.")
                        ToolTip.visible: partialHover.hovered

                        HoverHandler {
                            id: partialHover
                        }
                    }
                    ShellButton {
                        objectName: "diffCopyPath"
                        subtle: true
                        iconName: "copy"
                        iconSize: Theme.icon.sm
                        iconTint: root.muted
                        implicitWidth: Theme.control.sm
                        implicitHeight: Theme.control.sm
                        Accessible.name: qsTr("Copy the path of %1").arg(header.row.path)
                        ToolTip.visible: hovered
                        ToolTip.text: qsTr("Copy path")
                        onClicked: Shell.dispatch("files.copyPath", {
                            path: header.row.path
                        })
                    }
                    ShellButton {
                        objectName: "diffOpenInEditor"
                        // A thread's checkout has the file; a pull request's code may not.
                        visible: root.source?.hasTurns ?? true
                        // A file outside the thread's folder is not the thread's to open.
                        enabled: header.inWorkspace.length > 0
                        subtle: true
                        iconName: "square-arrow-out-up-right"
                        iconSize: Theme.icon.sm
                        iconTint: root.muted
                        implicitWidth: Theme.control.sm
                        implicitHeight: Theme.control.sm
                        Accessible.name: qsTr("Open %1 in the editor").arg(header.row.path)
                        ToolTip.visible: hovered
                        ToolTip.text: enabled ? qsTr("Open in editor") : qsTr("Not in this thread's folder")
                        onClicked: Shell.dispatch("workspace.openFile", {
                            path: header.inWorkspace
                        })
                    }
                    ShellButton {
                        objectName: "diffFileMenu"
                        visible: (root.source?.hasTurns ?? true) && root.editors.length > 0
                        enabled: header.inWorkspace.length > 0
                        subtle: true
                        iconName: "ellipsis"
                        iconSize: Theme.icon.sm
                        iconTint: root.muted
                        implicitWidth: Theme.control.sm
                        implicitHeight: Theme.control.sm
                        Accessible.name: qsTr("Actions for %1").arg(header.row.path)
                        onClicked: fileMenu.show(this, header.inWorkspace)
                    }
                    ShellButton {
                        readonly property bool viewed: (root.source?.viewedPaths ?? []).indexOf(header.row.path) >= 0

                        objectName: "diffViewed"
                        visible: typeof root.source?.setViewed === "function"
                        subtle: true
                        iconName: viewed ? "square-check" : "square"
                        iconSize: Theme.icon.sm
                        iconTint: viewed ? root.added : root.muted
                        implicitWidth: Theme.control.sm
                        implicitHeight: Theme.control.sm
                        Accessible.name: viewed ? qsTr("Mark %1 not viewed").arg(header.row.path) : qsTr("Mark %1 viewed").arg(header.row.path)
                        ToolTip.visible: hovered
                        ToolTip.text: viewed ? qsTr("Viewed") : qsTr("Mark viewed")
                        onClicked: root.source.setViewed(header.row.path, !viewed)
                    }
                    Text {
                        visible: header.row.binary
                        text: qsTr("binary")
                        color: root.muted
                        font.pixelSize: Theme.type.caption.size
                    }
                    Text {
                        text: "+" + header.row.additions
                        color: root.added
                        font.pixelSize: Theme.type.meta.size
                        font.features: { "tnum": 1 }
                    }
                    Text {
                        Layout.rightMargin: Theme.space.sm
                        text: "−" + header.row.deletions
                        color: root.removed
                        font.pixelSize: Theme.type.meta.size
                        font.features: { "tnum": 1 }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.control.lg - Theme.space.xs
                    Layout.leftMargin: 2 * Theme.space.sm + Theme.icon.sm
                    visible: header.waiting
                    spacing: Theme.space.sm

                    Text {
                        objectName: "diffFileNote"
                        text: header.row.note.length > 0 ? header.row.note : qsTr("Loading…")
                        color: header.row.state === "error" ? root.removed : root.muted
                        font.pixelSize: Theme.type.meta.size
                        elide: Text.ElideRight
                        Layout.maximumWidth: view.width - 6 * Theme.space.xl
                    }
                    ShellButton {
                        objectName: "diffFileRetry"
                        visible: header.row.state === "error"
                        subtle: true
                        implicitHeight: Theme.control.sm
                        text: qsTr("Retry loading diff")
                        onClicked: root.source.retryFile(header.row.path)
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                }
            }
        }
    }

    Component {
        id: hunkHeader

        Rectangle {
            readonly property var row: parent
            height: Theme.control.sm
            color: Theme.palette.color("inset", "#0a0b0d")

            // Kept in view while the lines scroll sideways, like the file header.
            // Cut in the middle, so the ranges and the enclosing name both
            // show; the whole header is on hover.
            Text {
                objectName: "diffHunkHeader"
                x: view.gutter + Math.max(0, view.contentX - view.originX)
                width: Math.max(0, view.width - view.gutter - Theme.space.sm)
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideMiddle
                HoverHandler {
                    id: hunkHover
                }
                ToolTip.visible: hunkHover.hovered && truncated
                ToolTip.delay: 500
                ToolTip.text: text
                text: parent.row.path
                color: root.muted
                font.family: root.mono
                font.pixelSize: Theme.type.meta.size
                font.features: { "tnum": 1 }
            }
        }
    }

    // A row's end padding while the lines scroll sideways: pinned to the
    // view's right edge in the row's own tint, so code is cut short of the
    // panel's edge rather than running into it.
    component EndPad: Rectangle {
        property color tint: "transparent"
        objectName: "diffLineEnd"
        x: Math.max(0, view.contentX - view.originX) + view.width - width
        width: Theme.space.sm
        height: parent.height
        visible: root.sideways
        color: root.color
        Rectangle {
            anchors.fill: parent
            color: parent.tint
        }
    }

    component LineNumber: Text {
        width: glyph.advanceWidth * 5
        horizontalAlignment: Text.AlignRight
        color: root.muted
        font.family: root.mono
        font.pixelSize: Theme.fontSizeCode
        font.features: { "tnum": 1 }
        topPadding: Theme.space.xxs
    }

    component LineText: Text {
        property string sign: " "
        // The line as the diff has it.
        property string line: ""
        // Wrapped, the line breaks between words (inside one only where a
        // single word is wider than the room) and the rest hangs under its
        // indentation, at most half the line's room (codeWidth, not this
        // width: that follows the wrap and would loop back here).
        readonly property real hang: root.wrap ? Math.min(root.indent(line), root.codeWidth / 2) : 0
        color: sign === "\\" ? root.muted : root.foreground
        font.family: root.mono
        font.pixelSize: Theme.fontSizeCode
        textFormat: Text.PlainText
        wrapMode: root.wrap ? Text.WrapAtWordBoundaryOrAnywhere : Text.NoWrap
        leftPadding: hang
        text: root.lineText(hang > 0 ? line.replace(/^[ \t]*/, "") : line)
        topPadding: 1
        bottomPadding: 1
    }

    // A side a line is not on has no number (DiffModel gives it 0).
    function lineNumber(line) {
        return line > 0 ? String(line) : "";
    }

    function tint(sign) {
        return sign === "+" ? root.addedSurface : sign === "-" ? root.removedSurface : "transparent";
    }

    Component {
        id: stackedLine

        Rectangle {
            id: stackedRow
            readonly property var row: parent
            objectName: "diffLine"
            implicitHeight: Math.max(Theme.icon.md + Theme.space.xxs, lineText.implicitHeight)
            height: implicitHeight
            color: root.tint(row.sign)

            LineText {
                id: lineText
                x: view.gutter
                width: root.wrap ? parent.width - x - Theme.space.sm : implicitWidth
                sign: parent.row.sign
                line: parent.row.text
            }
            // A note on this line (and the ones after it) for the prompt.
            HoverHandler {
                id: lineHover
            }
            TapHandler {
                enabled: root.touchLines && root.canComment && stackedRow.row.sign !== "\\"
                onTapped: commentPopup.ask(root.model.path(stackedRow.row.file), stackedRow.row.sign === "-" ? "old" : "new", stackedRow.row.sign === "-" ? stackedRow.row.oldLine : stackedRow.row.newLine)
            }
            // The numbers and the sign stay put while the line scrolls
            // sideways under them.
            Rectangle {
                x: Math.max(0, view.contentX - view.originX)
                width: view.gutter
                height: parent.height
                color: x > 0 ? root.color : "transparent"
                Rectangle {
                    anchors.fill: parent
                    visible: parent.x > 0
                    color: root.tint(stackedRow.row.sign)
                }
                Row {
                    id: numbers
                    x: view.commentInset
                    spacing: Theme.space.sm
                    LineNumber {
                        objectName: "diffOldLine"
                        text: root.lineNumber(stackedRow.row.oldLine)
                    }
                    LineNumber {
                        objectName: "diffNewLine"
                        text: root.lineNumber(stackedRow.row.newLine)
                    }
                }
                Text {
                    x: view.commentInset + view.numbersWidth + Theme.space.sm
                    text: stackedRow.row.sign === "\\" ? "" : stackedRow.row.sign
                    color: stackedRow.row.sign === "+" ? root.added : root.removed
                    font.family: root.mono
                    font.pixelSize: Theme.fontSizeCode
                    topPadding: 1
                }
                ShellButton {
                    readonly property var row: stackedRow.row
                    objectName: "diffLineComment"
                    x: Theme.space.xxs
                    width: Theme.icon.md
                    height: Math.min(parent.height, Theme.icon.md + Theme.space.xxs)
                    visible: root.canComment && row.sign !== "\\" && (lineHover.hovered || hovered)
                    subtle: true
                    iconName: "message-square-plus"
                    iconSize: Theme.icon.sm
                    iconTint: root.muted
                    Accessible.name: qsTr("Comment on this line")
                    onClicked: commentPopup.ask(root.model.path(row.file), row.sign === "-" ? "old" : "new", row.sign === "-" ? row.oldLine : row.newLine)
                }
            }
            EndPad {
                tint: root.tint(stackedRow.row.sign)
            }
        }
    }

    Component {
        id: splitLine

        Item {
            id: pair

            readonly property var row: parent
            readonly property real half: (width - glyph.advanceWidth * 12) / 2
            implicitHeight: Math.max(Theme.icon.md + Theme.space.xxs, left.implicitHeight, right.implicitHeight)
            height: implicitHeight

            Rectangle {
                width: pair.width / 2
                height: pair.height
                color: pair.row.sign.length > 0 ? root.tint(pair.row.sign) : Theme.palette.color("inset", "#0a0b0d")
                LineNumber {
                    text: pair.row.sign.length > 0 ? root.lineNumber(pair.row.oldLine) : ""
                }
                LineText {
                    id: left
                    x: glyph.advanceWidth * 6
                    width: pair.half - Theme.space.sm
                    clip: !root.wrap
                    sign: pair.row.sign
                    line: pair.row.text
                }
            }
            Rectangle {
                x: pair.width / 2
                width: pair.width / 2
                height: pair.height
                color: pair.row.rightSign.length > 0 ? root.tint(pair.row.rightSign) : Theme.palette.color("inset", "#0a0b0d")
                LineNumber {
                    text: pair.row.rightSign.length > 0 ? root.lineNumber(pair.row.newLine) : ""
                }
                LineText {
                    id: right
                    x: glyph.advanceWidth * 6
                    width: pair.half - Theme.space.sm
                    clip: !root.wrap
                    sign: pair.row.rightSign
                    line: pair.row.rightText
                }
            }
            EndPad {
                // In the tint of the side under the view's right edge.
                readonly property bool onRight: x >= pair.width / 2
                tint: onRight ? (pair.row.rightSign.length > 0 ? root.tint(pair.row.rightSign) : Theme.palette.color("inset", "#0a0b0d")) : (pair.row.sign.length > 0 ? root.tint(pair.row.sign) : Theme.palette.color("inset", "#0a0b0d"))
            }
        }
    }

    RevertDialog {
        id: confirm
        source: root.source
    }

    // What the environment can open a diff file with (`path` is the workspace's).
    ShellMenu {
        id: fileMenu

        property string path: ""

        function show(button, path) {
            fileMenu.path = path;
            const at = button.mapToItem(root, 0, button.height);
            fileMenu.x = at.x;
            fileMenu.y = at.y;
            open();
        }

        objectName: "diffFileActions"
        implicitWidth: 7 * Theme.space.xl

        ShellMenuItem {
            objectName: "diffFileOpen"
            visible: root.hasFileManager
            height: visible ? implicitHeight : 0
            text: qsTr("Open")
            onTriggered: Shell.dispatch("files.openInEditor", {
                path: fileMenu.path,
                editorId: "file-manager"
            })
        }
        ShellMenuItem {
            objectName: "diffFileReveal"
            visible: root.hasFileManager
            height: visible ? implicitHeight : 0
            text: Shell.state.workspace?.revealLabel ?? qsTr("Reveal in file manager")
            onTriggered: Shell.dispatch("files.reveal", {
                path: fileMenu.path
            })
        }
        Repeater {
            model: root.editors.filter(editor => editor.id !== "file-manager")

            ShellMenuItem {
                required property var modelData

                objectName: "diffFileEditor-" + modelData.id
                text: qsTr("Open in %1").arg(modelData.label)
                onTriggered: Shell.dispatch("files.openInEditor", {
                    path: fileMenu.path,
                    editorId: modelData.id
                })
            }
        }
    }

    // A note on lines of the diff, added to the prompt as review context.
    Popup {
        id: commentPopup
        objectName: "diffCommentPopup"

        property string path: ""
        property string side: "new"
        property int first: 0

        function ask(path, side, line) {
            commentPopup.path = path;
            commentPopup.side = side;
            commentPopup.first = line;
            commentLast.text = String(line);
            commentNote.text = "";
            open();
            commentNote.forceActiveFocus();
        }
        function submit() {
            const last = Math.max(commentPopup.first, parseInt(commentLast.text) || commentPopup.first);
            if (root.source.comment(commentPopup.path, commentPopup.side, commentPopup.first, last, commentNote.text))
                close();
        }

        parent: Overlay.overlay
        scale: Shell.state.layout?.zoom ?? 1
        transformOrigin: Item.TopLeft
        x: Math.round((parent.width - width * scale) / 2)
        y: Math.round((parent.height - height * scale) / 2)
        width: Math.min(12 * Theme.space.xl, parent.width / scale - Theme.space.xl)
        modal: true
        padding: Theme.space.md

        Overlay.modal: ShellScrim {}
        background: ShellPopoverSurface {}

        contentItem: ColumnLayout {
            spacing: Theme.space.sm

            Text {
                Layout.fillWidth: true
                text: qsTr("Comment on %1").arg(commentPopup.path)
                color: root.foreground
                font.pixelSize: Theme.type.body.size
                font.weight: Font.DemiBold
                elide: Text.ElideMiddle
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.space.sm

                Text {
                    text: qsTr("From line %1 to").arg(commentPopup.first)
                    color: root.muted
                    font.pixelSize: Theme.type.meta.size
                }
                ShellTextField {
                    id: commentLast

                    objectName: "diffCommentLast"
                    Layout.preferredWidth: 2 * Theme.space.xl
                    implicitHeight: Theme.control.md
                    inputMethodHints: Qt.ImhDigitsOnly
                    Accessible.name: qsTr("Last line")
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 3 * Theme.control.md
                radius: Theme.radiusMd
                color: Theme.palette.color("input", "#141416")
                border.color: commentNote.activeFocus ? Theme.palette.color("focus", "#3b82f6") : root.borderColor

                ScrollView {
                    anchors.fill: parent
                    anchors.margins: Theme.space.sm

                    // Enter starts a new line; mod+enter adds the comment.
                    TextArea {
                        id: commentNote

                        objectName: "diffCommentNote"
                        placeholderText: qsTr("What should change here?")
                        Accessible.name: qsTr("Comment")
                        placeholderTextColor: root.muted
                        color: root.foreground
                        wrapMode: TextEdit.Wrap
                        background: null
                        font.pixelSize: Theme.type.body.size
                        // Before the window's shortcuts take it.
                        Keys.onShortcutOverride: event => {
                            if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & (Qt.ControlModifier | Qt.MetaModifier)))
                                event.accepted = true;
                        }
                        Keys.onPressed: event => {
                            if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & (Qt.ControlModifier | Qt.MetaModifier))) {
                                event.accepted = true;
                                if (commentNote.text.trim().length > 0)
                                    commentPopup.submit();
                            }
                        }
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.space.sm

                Item {
                    Layout.fillWidth: true
                }
                ShellButton {
                    text: qsTr("Cancel")
                    onClicked: commentPopup.close()
                }
                ShellButton {
                    objectName: "diffCommentAdd"
                    primary: true
                    text: qsTr("Add to prompt")
                    enabled: commentNote.text.trim().length > 0
                    onClicked: commentPopup.submit()
                }
            }
        }
    }
}
