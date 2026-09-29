import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The right panel's Diff tab: what a thread's turns changed, from a
// ThreadDiff (Panel.diff). A picker chooses the latest turn, all changes or
// one turn; the patch is a DiffModel drawn one row per line, so a large diff
// only makes the rows in view. Reverting to the turn shown asks first (RevertDialog).
//
//   DiffPanel { anchors.fill: parent; source: Panel.diff }
Rectangle {
    id: root

    property var source: null
    readonly property var model: source?.model ?? null
    readonly property string status: source?.status ?? "idle"
    readonly property bool wrap: source?.wrap ?? false
    readonly property bool split: model?.split ?? false
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
        font.pixelSize: 12
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
                text: qsTr("%n file(s)", "", root.model?.fileCount ?? 0)
                color: root.muted
                font.pixelSize: 12
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
                font.pixelSize: 12
                font.family: root.mono
            }
            Text {
                visible: root.status === "ready"
                text: "−" + (root.model?.deletions ?? 0)
                color: root.removed
                font.pixelSize: 12
                font.family: root.mono
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
                        text: qsTr("Reload")
                        onTriggered: root.source.reload()
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
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
                    font.pixelSize: 13
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
                    font.pixelSize: 12
                    font.strikeout: header.row.change === "deleted"
                    elide: Text.ElideMiddle
                }
                Text {
                    visible: header.row.binary
                    text: qsTr("binary")
                    color: root.muted
                    font.pixelSize: 11
                }
                Text {
                    text: "+" + header.row.additions
                    color: root.added
                    font.family: root.mono
                    font.pixelSize: 11
                }
                Text {
                    Layout.rightMargin: 10
                    text: "−" + header.row.deletions
                    color: root.removed
                    font.family: root.mono
                    font.pixelSize: 11
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
                font.pixelSize: 11
            }
        }
    }

    component LineNumber: Text {
        width: glyph.advanceWidth * 5
        horizontalAlignment: Text.AlignRight
        color: root.muted
        font.family: root.mono
        font.pixelSize: 11
        topPadding: 2
    }

    component LineText: Text {
        property string sign: " "
        color: sign === "\\" ? root.muted : root.foreground
        font.family: root.mono
        font.pixelSize: 12
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
                LineNumber { text: numbers.parent.row.oldLine ?? "" }
                LineNumber { text: numbers.parent.row.newLine ?? "" }
            }
            Text {
                x: view.gutter - glyph.advanceWidth * 2
                text: parent.row.sign === "\\" ? "" : parent.row.sign
                color: parent.row.sign === "+" ? root.added : root.removed
                font.family: root.mono
                font.pixelSize: 12
                topPadding: 1
            }
            LineText {
                id: lineText
                x: view.gutter
                width: root.wrap ? parent.width - x - 8 : implicitWidth
                sign: parent.row.sign
                text: root.lineText(parent.row.text)
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
                LineNumber { text: pair.row.sign.length > 0 ? pair.row.oldLine ?? "" : "" }
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
                LineNumber { text: pair.row.rightSign.length > 0 ? pair.row.newLine ?? "" : "" }
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
}
