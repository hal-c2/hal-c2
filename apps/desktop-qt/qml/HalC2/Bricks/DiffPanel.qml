import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The right panel's Diff tab: what a thread's turns changed, from a
// ThreadDiff (Panel.diff). A picker chooses the latest turn, all changes or
// one turn; the patch is a DiffModel drawn one row per line, so a large diff
// only makes the rows in view. Reverting to the turn shown asks first (RevertDialog).
// The picker also offers the checkout itself: its working tree, or the branch
// against a base the user can name. The changed files can be listed as a tree
// that jumps to a file, and a file opens in the user's editor.
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
    readonly property bool wrap: source?.wrap ?? false
    readonly property bool split: model?.split ?? false
    // One file of the selection is shown alone (ThreadDiff.focusPath).
    readonly property bool focused: (source?.focusPath ?? "").length > 0
    // Lines can be commented on for the prompt (a thread's diff; a pull
    // request's code has the host's own review).
    readonly property bool canComment: source?.reviewing !== undefined
    // The branch is what is reviewed, against `source.comparedBase`.
    readonly property bool comparing: (source?.reviewing ?? false) && source.selection === -3
    // Whether the changed files are listed as a tree beside the diff.
    property bool showTree: false
    readonly property var tree: showTree && model !== null && status === "ready" && model.fileCount > 0 ? model.tree() : []

    // Opens `file` and brings it to the top.
    function jumpTo(file) {
        root.model.setExpanded(file, true);
        view.positionViewAtIndex(root.model.rowOfFile(file), ListView.Beginning);
    }
    // Characters drawn of one line; the rest of a minified line is cut.
    readonly property int maxLineColumns: 2000

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color border: Theme.palette.color("border", "#27272a")
    readonly property color added: Theme.palette.color("diffAdded", "#22c55e")
    readonly property color removed: Theme.palette.color("diffRemoved", "#ef4444")
    readonly property string mono: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"

    objectName: "diffPanel"
    color: Theme.palette.color("surface", "#0f0f11")

    function lineText(text) {
        return text.length > maxLineColumns ? text.slice(0, maxLineColumns) + "…" : text;
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
            Layout.margins: 8
            spacing: 6

            ShellComboBox {
                id: picker

                objectName: "diffTurnPicker"
                Layout.preferredWidth: 150
                visible: root.source?.hasTurns ?? true
                outline: true
                model: root.source?.choices ?? []
                textRole: "label"
                valueRole: "value"
                enabled: count > 0
                currentIndex: Math.max(0, indexOfValue(root.source?.selection ?? -1))
                onActivated: root.source.select(currentValue)
            }

            Text {
                Layout.fillWidth: true
                visible: root.status === "ready"
                text: root.focused ? qsTr("1 of %n file(s)", "", root.source.fileTotal) : qsTr("%n file(s)", "", root.model?.fileCount ?? 0)
                color: root.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
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
                font.pixelSize: Theme.fontSizeCode
                font.family: root.mono
            }
            Text {
                visible: root.status === "ready"
                text: "−" + (root.model?.deletions ?? 0)
                color: root.removed
                font.pixelSize: Theme.fontSizeCode
                font.family: root.mono
            }

            ShellButton {
                objectName: "diffShowAllFiles"
                visible: root.focused && root.status === "ready"
                subtle: true
                implicitHeight: 28
                text: qsTr("Show all files")
                onClicked: root.source.showAllFiles()
            }

            ShellButton {
                objectName: "diffRevert"
                subtle: true
                iconName: "undo-2"
                iconSize: 14
                iconTint: root.muted
                implicitWidth: 28
                implicitHeight: 28
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
                iconSize: 14
                iconTint: root.muted
                implicitWidth: 28
                implicitHeight: 28
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
                        text: root.wrap ? qsTr("Don't wrap lines") : qsTr("Wrap lines")
                        onTriggered: root.source.wrap = !root.wrap
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
            Layout.leftMargin: 8
            Layout.rightMargin: 8
            Layout.bottomMargin: 8
            visible: root.comparing
            spacing: 6

            Text {
                text: qsTr("%1 against").arg(root.source?.comparedHead || qsTr("HEAD"))
                color: root.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
                elide: Text.ElideMiddle
            }
            ShellTextField {
                objectName: "diffBaseRef"
                Layout.fillWidth: true
                implicitHeight: 26
                placeholderText: root.source?.comparedBase || qsTr("the base branch")
                text: root.source?.baseRef ?? ""
                Accessible.name: qsTr("Compare against")
                onAccepted: root.source.baseRef = text
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: root.border
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            ListView {
                id: treeView

                objectName: "diffTreeRows"
                Layout.preferredWidth: Math.min(240, root.width * 0.35)
                Layout.fillHeight: true
                visible: root.tree.length > 0
                clip: true
                model: root.tree
                boundsBehavior: Flickable.StopAtBounds
                delegate: ItemDelegate {
                    id: node

                    required property var modelData

                    objectName: "diffTreeNode"
                    width: treeView.width
                    height: 24
                    padding: 0
                    leftPadding: 8 + node.modelData.depth * 12
                    enabled: node.modelData.kind === "file"
                    Accessible.name: node.modelData.path
                    onClicked: root.jumpTo(node.modelData.file)
                    background: Rectangle {
                        color: node.hovered ? Theme.palette.color("surfaceRaised", "#1f1f24") : "transparent"
                    }
                    contentItem: RowLayout {
                        spacing: 6

                        ShellIcon {
                            name: node.modelData.kind === "folder" ? "folder" : "file"
                            size: 13
                            color: root.muted
                        }
                        Text {
                            Layout.fillWidth: true
                            text: node.modelData.name
                            color: node.modelData.kind === "folder" ? root.muted : root.foreground
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            elide: Text.ElideMiddle
                        }
                    }
                }
            }
            Rectangle {
                Layout.preferredWidth: 1
                Layout.fillHeight: true
                visible: treeView.visible
                color: root.border
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                ColumnLayout {
                    objectName: "diffMessage"
                    anchors.centerIn: parent
                    width: parent.width - 32
                    visible: root.status !== "ready"
                    spacing: 10

                    Text {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        text: root.status === "idle" ? "" : root.source?.message ?? ""
                        color: root.status === "error" ? root.removed : root.muted
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                        wrapMode: Text.Wrap
                    }
                    ShellButton {
                        objectName: "diffRetry"
                        Layout.alignment: Qt.AlignHCenter
                        visible: root.status === "error"
                        text: qsTr("Try again")
                        onClicked: root.source.reload()
                    }
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
                    readonly property real gutter: glyph.advanceWidth * 10 + 24
                    readonly property real rowWidth: gutter + glyph.advanceWidth * Math.min(root.model?.maxColumns ?? 0, root.maxLineColumns) * (root.split ? 2 : 1) + 24
                    ScrollBar.vertical: ScrollBar {}
                    ScrollBar.horizontal: ScrollBar {}

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
            objectName: "diffFile-" + row.path
            height: 32
            hoverEnabled: true
            // The header's text stays in view while the lines scroll sideways.
            leftPadding: Math.max(0, view.contentX - view.originX)
            rightPadding: Math.max(0, width - leftPadding - view.width)
            Accessible.name: row.path
            onClicked: root.model.toggle(row.file)
            background: Rectangle {
                color: header.hovered ? Theme.palette.color("surfaceRaised", "#1f1f24") : Theme.palette.color("chrome", "#0b0b0d")
                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: 1
                    color: root.border
                }
            }
            contentItem: RowLayout {
                spacing: 6

                ShellIcon {
                    Layout.leftMargin: 8
                    name: header.row.expanded ? "chevron-down" : "chevron-right"
                    size: 13
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
                ShellButton {
                    objectName: "diffOpenInEditor"
                    // A thread's checkout has the file; a pull request's code may not.
                    visible: root.source?.hasTurns ?? true
                    subtle: true
                    iconName: "square-arrow-out-up-right"
                    iconSize: 13
                    iconTint: root.muted
                    implicitWidth: 24
                    implicitHeight: 24
                    Accessible.name: qsTr("Open %1 in the editor").arg(header.row.path)
                    ToolTip.visible: hovered
                    ToolTip.text: qsTr("Open in editor")
                    onClicked: Shell.dispatch("workspace.openFile", {
                        path: header.row.path
                    })
                }
                ShellButton {
                    readonly property bool viewed: (root.source?.viewedPaths ?? []).indexOf(header.row.path) >= 0

                    objectName: "diffViewed"
                    visible: typeof root.source?.setViewed === "function"
                    subtle: true
                    iconName: viewed ? "square-check" : "square"
                    iconSize: 13
                    iconTint: viewed ? root.added : root.muted
                    implicitWidth: 24
                    implicitHeight: 24
                    Accessible.name: viewed ? qsTr("Mark %1 not viewed").arg(header.row.path) : qsTr("Mark %1 viewed").arg(header.row.path)
                    ToolTip.visible: hovered
                    ToolTip.text: viewed ? qsTr("Viewed") : qsTr("Mark viewed")
                    onClicked: root.source.setViewed(header.row.path, !viewed)
                }
                Text {
                    visible: header.row.binary
                    text: qsTr("binary")
                    color: root.muted
                    font.pixelSize: Math.round(11 * Theme.fontScale)
                }
                Text {
                    text: "+" + header.row.additions
                    color: root.added
                    font.family: root.mono
                    font.pixelSize: Theme.fontSizeCode
                }
                Text {
                    Layout.rightMargin: 10
                    text: "−" + header.row.deletions
                    color: root.removed
                    font.family: root.mono
                    font.pixelSize: Theme.fontSizeCode
                }
            }
        }
    }

    Component {
        id: hunkHeader

        Rectangle {
            readonly property var row: parent
            height: 22
            color: Qt.alpha(Theme.palette.color("accent", "#3b82f6"), 0.08)

            Text {
                x: view.gutter
                anchors.verticalCenter: parent.verticalCenter
                text: parent.row.path
                color: root.muted
                font.family: root.mono
                font.pixelSize: Theme.fontSizeCode
            }
        }
    }

    component LineNumber: Text {
        width: glyph.advanceWidth * 5
        horizontalAlignment: Text.AlignRight
        color: root.muted
        font.family: root.mono
        font.pixelSize: Theme.fontSizeCode
        topPadding: 2
    }

    component LineText: Text {
        property string sign: " "
        color: sign === "\\" ? root.muted : root.foreground
        font.family: root.mono
        font.pixelSize: Theme.fontSizeCode
        textFormat: Text.PlainText
        wrapMode: root.wrap ? Text.WrapAnywhere : Text.NoWrap
        topPadding: 1
        bottomPadding: 1
    }

    function tint(sign) {
        return sign === "+" ? Qt.alpha(root.added, 0.12) : sign === "-" ? Qt.alpha(root.removed, 0.12) : "transparent";
    }

    Component {
        id: stackedLine

        Rectangle {
            readonly property var row: parent
            implicitHeight: Math.max(18, lineText.implicitHeight)
            height: implicitHeight
            color: root.tint(row.sign)

            Row {
                id: numbers
                spacing: 6
                LineNumber {
                    text: numbers.parent.row.oldLine ?? ""
                }
                LineNumber {
                    text: numbers.parent.row.newLine ?? ""
                }
            }
            Text {
                x: view.gutter - glyph.advanceWidth * 2
                text: parent.row.sign === "\\" ? "" : parent.row.sign
                color: parent.row.sign === "+" ? root.added : root.removed
                font.family: root.mono
                font.pixelSize: Theme.fontSizeCode
                topPadding: 1
            }
            LineText {
                id: lineText
                x: view.gutter
                width: root.wrap ? parent.width - x - 8 : implicitWidth
                sign: parent.row.sign
                text: root.lineText(parent.row.text)
            }
            // A note on this line (and the ones after it) for the prompt.
            HoverHandler {
                id: lineHover
            }
            ShellButton {
                readonly property var row: parent.row
                objectName: "diffLineComment"
                x: 2
                width: 16
                height: Math.min(parent.height, 18)
                visible: root.canComment && row.sign !== "\\" && (lineHover.hovered || hovered)
                subtle: true
                iconName: "message-square-plus"
                iconSize: 11
                iconTint: root.muted
                Accessible.name: qsTr("Comment on this line")
                onClicked: commentPopup.ask(root.model.path(row.file), row.sign === "-" ? "old" : "new", row.sign === "-" ? row.oldLine : row.newLine)
            }
        }
    }

    Component {
        id: splitLine

        Item {
            id: pair

            readonly property var row: parent
            readonly property real half: (width - glyph.advanceWidth * 12) / 2
            implicitHeight: Math.max(18, left.implicitHeight, right.implicitHeight)
            height: implicitHeight

            Rectangle {
                width: pair.width / 2
                height: pair.height
                color: pair.row.sign.length > 0 ? root.tint(pair.row.sign) : Qt.alpha(root.muted, 0.06)
                LineNumber {
                    text: pair.row.sign.length > 0 ? pair.row.oldLine ?? "" : ""
                }
                LineText {
                    id: left
                    x: glyph.advanceWidth * 6
                    width: pair.half - 8
                    clip: !root.wrap
                    sign: pair.row.sign
                    text: root.lineText(pair.row.text)
                }
            }
            Rectangle {
                x: pair.width / 2
                width: pair.width / 2
                height: pair.height
                color: pair.row.rightSign.length > 0 ? root.tint(pair.row.rightSign) : Qt.alpha(root.muted, 0.06)
                LineNumber {
                    text: pair.row.rightSign.length > 0 ? pair.row.newLine ?? "" : ""
                }
                LineText {
                    id: right
                    x: glyph.advanceWidth * 6
                    width: pair.half - 8
                    clip: !root.wrap
                    sign: pair.row.rightSign
                    text: root.lineText(pair.row.rightText)
                }
            }
        }
    }

    RevertDialog {
        id: confirm
        source: root.source
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
        width: 380
        modal: true
        padding: 14

        background: Rectangle {
            radius: Theme.radius
            color: Theme.palette.color("surfaceOverlay", "#18181b")
            border.color: root.border
            border.width: 1
        }

        contentItem: ColumnLayout {
            spacing: 8

            Text {
                Layout.fillWidth: true
                text: qsTr("Comment on %1").arg(commentPopup.path)
                color: root.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.DemiBold
                elide: Text.ElideMiddle
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Text {
                    text: qsTr("From line %1 to").arg(commentPopup.first)
                    color: root.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }
                ShellTextField {
                    id: commentLast

                    objectName: "diffCommentLast"
                    Layout.preferredWidth: 70
                    implicitHeight: 26
                    inputMethodHints: Qt.ImhDigitsOnly
                    Accessible.name: qsTr("Last line")
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            ShellTextField {
                id: commentNote

                objectName: "diffCommentNote"
                Layout.fillWidth: true
                placeholderText: qsTr("What should change here?")
                Accessible.name: qsTr("Comment")
                onAccepted: commentPopup.submit()
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 6

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
