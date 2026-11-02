pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// One block of a page (a row of Spaces.blocks): its text edited in place and
// written when the user leaves it or presses Return, a heading sized by its
// level, a checklist item's tick, a callout's tint, a subpage link that opens
// the page, an image above its caption, a chart drawn from its description,
// what a page's update wrote (Markdown nobody edits by hand), Markdown the page
// keeps as written (a raw block: its source in a fixed-width face, never
// wrapped, scrolled sideways, and written with Ctrl+Return or by leaving it), a
// Mermaid diagram drawn from a raw block's source, and the block's own actions
// (comment, add a block below, ask again for a chart, switch a diagram to its
// source, move up or down, delete).
Item {
    id: block

    required property string blockId
    required property string kind
    required property string text
    required property bool checked
    required property string linkedPageId
    required property string linkedTitle
    required property bool byAgent
    required property int openComments
    required property string imageId
    required property string imageState
    required property string imageUrl
    required property int imageWidth
    required property int imageHeight
    // Where it is on the page, and the blocks either side ("" at an end).
    required property int index
    property string previousId: ""
    property string beforePreviousId: ""
    property string nextId: ""
    property bool readOnly: false
    // A heading's level, 1 to 6 (0 or none counts as 2).
    property int level: 0
    // A chart block's description (SpaceChart in packages/contracts).
    property var chart: ({})

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color info: Theme.palette.color("info", "#3b82f6")
    readonly property bool editing: editor.activeFocus
    readonly property bool raw: kind === "raw"
    // Level 2 keeps the page's usual heading; 1 is larger, 3 to 6 step down.
    readonly property int headingSize: [26, 20, 17, 16, 15, 14][Math.max(1, Math.min(6, level || 2)) - 1]
    // A raw block that is one "mermaid" fence is drawn in place of its text,
    // until the user switches to the source; what they write there is drawn
    // once it is saved.
    readonly property string diagramCode: block.raw ? block.mermaidOf(block.text) : ""
    property bool diagramSource: false
    readonly property bool diagramShown: diagramCode.length > 0 && diagram.drawn && !diagramSource

    signal commentRequested(string blockId)
    signal addBelowRequested(string blockId)
    signal askAgainRequested(string blockId, string request)

    // The source of the one fenced "mermaid" block `text` is, or "".
    function mermaidOf(text) {
        const fence = /^ {0,3}(`{3,}|~{3,})[ \t]*mermaid[ \t]*\r?\n([\s\S]*?)\r?\n {0,3}\1[`~]*[ \t]*(?:\r?\n)?$/i.exec(text);
        return fence ? fence[2] : "";
    }

    // Writes what the user typed, if it differs from the block's text.
    function commit() {
        const typed = editor.text;
        if (typed !== block.text && !block.readOnly)
            Shell.dispatch("space.block.update", { blockId: block.blockId, text: typed });
    }

    objectName: "spaceBlock:" + text
    implicitHeight: Math.max(row.implicitHeight, 28) + (block.kind === "heading" ? 10 : block.raw ? 16 : 4) + (picture.visible ? picture.height + 6 : 0) + diagramNote.height

    // The editor follows the block, and a diagram is drawn again, while the
    // user is not writing in it.
    onTextChanged: {
        if (editor.activeFocus)
            return;
        editor.text = block.text;
        block.diagramSource = false;
    }

    HoverHandler {
        id: hover
    }

    Rectangle {
        anchors.fill: parent
        anchors.topMargin: 1
        anchors.bottomMargin: 1
        radius: Math.min(Theme.radius, 8)
        visible: block.kind === "callout"
        color: Qt.alpha(block.info, Theme.appearance === "dark" ? 0.14 : 0.08)
        border.color: Qt.alpha(block.info, 0.4)
    }

    Rectangle {
        anchors.fill: parent
        anchors.topMargin: 1
        anchors.bottomMargin: 1
        radius: Math.min(Theme.radius, 8)
        visible: block.raw && !block.diagramShown
        color: Theme.palette.color("codeBackground", "#111111")
        border.color: Theme.palette.color("border", "#191919")
    }

    SpaceBlockImage {
        id: picture

        objectName: "spaceBlockImage:" + block.text
        anchors.top: parent.top
        anchors.left: parent.left
        width: Math.min(parent.width, 720)
        visible: block.kind === "image"
        imageId: block.imageId
        state_: block.imageState
        url: block.imageUrl
        naturalWidth: block.imageWidth
        naturalHeight: block.imageHeight
        readOnly: block.readOnly
    }

    // Why the diagram is not drawn (yet), under its source.
    MermaidDiagram {
        id: diagramNote

        objectName: "spaceDiagramNote:" + block.text
        anchors.top: row.bottom
        anchors.left: row.left
        anchors.right: row.right
        height: implicitHeight
        active: block.diagramCode.length > 0
        code: block.diagramCode
        showPicture: false
        padding: 0
    }

    RowLayout {
        id: row

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: (picture.visible ? (picture.height + 6) / 2 : 0) - diagramNote.height / 2
        anchors.leftMargin: block.kind === "callout" || block.raw ? 10 : 0
        spacing: 8

        ShellCheckBox {
            objectName: "spaceTick:" + block.text
            Accessible.name: block.text
            visible: block.kind === "checklist"
            padding: 0
            checked: block.checked
            enabled: !block.readOnly
            onToggled: {
                Shell.dispatch("space.block.setChecked", { blockId: block.blockId, checked: checked });
                // The pending tick, then the stream, says what it is.
                checked = Qt.binding(() => block.checked);
            }
        }

        ShellIcon {
            visible: block.kind === "callout"
            name: "info"
            size: 16
            color: block.info
        }

        ShellIcon {
            visible: block.kind === "subpage_link"
            name: "file-text"
            size: 16
            color: block.muted
        }

        Text {
            id: link

            objectName: "spaceLink:" + block.linkedTitle
            Layout.fillWidth: true
            visible: block.kind === "subpage_link"
            text: block.linkedTitle
            color: Theme.palette.color("accent", "#3b82f6")
            font.pixelSize: Math.round(15 * Theme.fontScale)
            font.underline: linkMouse.containsMouse
            elide: Text.ElideRight

            MouseArea {
                id: linkMouse

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Shell.dispatch("space.selectPage", { pageId: block.linkedPageId })
            }
        }

        Loader {
            Layout.fillWidth: true
            active: block.kind === "chart"
            visible: active

            sourceComponent: SpaceChart {
                chart: block.chart
            }
        }

        MermaidDiagram {
            id: diagram

            objectName: "spaceDiagram:" + block.text
            Layout.fillWidth: true
            Layout.preferredHeight: implicitHeight
            visible: block.diagramShown
            active: block.diagramCode.length > 0
            code: block.diagramCode
            showNote: false
            padding: 0
        }

        // The editor, which a raw block's long lines scroll sideways in: the
        // wheel's sideways axis or shift, as code in a reply does.
        Flickable {
            id: scroller

            objectName: "spaceBlockScroll:" + block.text
            Layout.fillWidth: true
            implicitHeight: editor.height
            visible: block.kind !== "subpage_link" && block.kind !== "chart" && block.kind !== "generated" && !block.diagramShown
            clip: block.raw
            interactive: false
            flickableDirection: Flickable.HorizontalFlick
            boundsBehavior: Flickable.StopAtBounds
            contentWidth: editor.width
            contentHeight: height

            TextEdit {
                id: editor

                objectName: "spaceBlockEditor:" + block.text
                width: block.raw ? Math.max(implicitWidth, scroller.width) : scroller.width
                readOnly: block.readOnly
                textFormat: TextEdit.PlainText
                wrapMode: block.raw ? TextEdit.NoWrap : TextEdit.Wrap
                selectByMouse: true
                color: block.foreground
                selectionColor: Theme.palette.color("accent", "#2563eb")
                selectedTextColor: Theme.palette.color("accentForeground", "#ffffff")
                font.family: block.raw ? (Theme.fontMono.length > 0 ? Theme.fontMono : "monospace") : Qt.application.font.family
                font.pixelSize: block.raw ? Theme.fontSizeCode : Math.round((block.kind === "heading" ? block.headingSize : 15) * Theme.fontScale)
                font.weight: block.kind === "heading" ? Font.DemiBold : Font.Normal
                font.strikeout: block.kind === "checklist" && block.checked
                // Source shows each character as typed, so no ligatures turn "---" or "->" into one glyph.
                font.features: block.raw ? { "liga": 0, "calt": 0 } : ({})
                opacity: block.kind === "checklist" && block.checked ? 0.7 : 1
                Component.onCompleted: text = block.text
                onActiveFocusChanged: {
                    if (!activeFocus) {
                        block.commit();
                        editor.text = block.text;
                    }
                }
                // The caret stays in sight on a line wider than the block.
                onCursorRectangleChanged: {
                    if (!block.raw)
                        return;
                    if (cursorRectangle.x < scroller.contentX)
                        scroller.contentX = cursorRectangle.x;
                    else if (cursorRectangle.x + cursorRectangle.width > scroller.contentX + scroller.width)
                        scroller.contentX = cursorRectangle.x + cursorRectangle.width - scroller.width;
                }
                // Return writes the block (by leaving it); Shift+Return starts a
                // new line in it. In a raw block, which is lines of source,
                // Return starts a line and Ctrl+Return writes it.
                Keys.onReturnPressed: event => {
                    if ((event.modifiers & Qt.ShiftModifier) || (block.raw && !(event.modifiers & Qt.ControlModifier))) {
                        event.accepted = false;
                        return;
                    }
                    editor.focus = false;
                }
                Keys.onEscapePressed: {
                    editor.text = block.text;
                    editor.focus = false;
                }
            }

            MouseArea {
                parent: scroller
                anchors.fill: parent
                enabled: block.raw
                acceptedButtons: Qt.NoButton
                onWheel: wheel => {
                    const dx = wheel.angleDelta.x !== 0 ? wheel.angleDelta.x : (wheel.modifiers & Qt.ShiftModifier) ? wheel.angleDelta.y : 0;
                    if (dx === 0 || scroller.contentWidth <= scroller.width) {
                        wheel.accepted = false;
                        return;
                    }
                    scroller.contentX = Math.max(0, Math.min(scroller.contentWidth - scroller.width, scroller.contentX - dx));
                }
            }
        }

        Loader {
            Layout.fillWidth: true
            active: block.kind === "generated"
            visible: active

            sourceComponent: ColumnLayout {
                spacing: 2

                Markdown {
                    objectName: "spaceGenerated"
                    Layout.fillWidth: true
                    text: block.text
                }

                Text {
                    text: qsTr("Written by this page's update")
                    color: block.muted
                    font.pixelSize: Math.round(11 * Theme.fontScale)
                }
            }
        }

        Text {
            visible: block.byAgent
            text: qsTr("agent")
            color: block.muted
            font.pixelSize: Math.round(11 * Theme.fontScale)
        }

        RowLayout {
            Layout.alignment: block.kind === "chart" || block.diagramShown ? Qt.AlignTop : Qt.AlignVCenter
            spacing: 0
            // Kept in the layout so the text does not reflow on hover.
            opacity: hover.hovered || block.editing || block.openComments > 0 ? 1 : 0

            ShellButton {
                objectName: "spaceComment:" + block.text
                subtle: true
                iconName: "message-square-plus"
                text: block.openComments > 0 ? String(block.openComments) : ""
                implicitHeight: 26
                toolTip: qsTr("Comment")
                Accessible.name: block.openComments > 0 ? qsTr("Comments, %1 open").arg(block.openComments) : qsTr("Comment")
                onClicked: block.commentRequested(block.blockId)
            }

            ShellButton {
                objectName: "spaceAddBelow:" + block.text
                subtle: true
                iconName: "plus"
                implicitHeight: 26
                implicitWidth: 26
                Accessible.name: qsTr("Add a block below")
                visible: !block.readOnly
                onClicked: block.addBelowRequested(block.blockId)
            }

            ShellButton {
                objectName: "spaceAskAgain:" + block.text
                subtle: true
                iconName: "refresh-cw"
                implicitHeight: 26
                implicitWidth: 26
                Accessible.name: qsTr("Ask again")
                toolTip: qsTr("Ask again")
                visible: block.kind === "chart" && !block.readOnly
                onClicked: block.askAgainRequested(block.blockId, block.chart.request ?? "")
            }

            ShellButton {
                objectName: "spaceDiagramSource:" + block.text
                subtle: true
                iconName: block.diagramSource ? "image" : "code"
                implicitHeight: 26
                implicitWidth: 26
                Accessible.name: block.diagramSource ? qsTr("Show the diagram") : qsTr("Show the source")
                toolTip: Accessible.name
                visible: block.diagramCode.length > 0 && diagram.drawn
                onClicked: block.diagramSource = !block.diagramSource
            }

            ShellButton {
                objectName: "spaceMoveUp:" + block.text
                subtle: true
                iconName: "arrow-up"
                implicitHeight: 26
                implicitWidth: 26
                Accessible.name: qsTr("Move up")
                visible: !block.readOnly
                enabled: block.previousId !== ""
                // After the block before the one above it; first when there is none.
                onClicked: Shell.dispatch("space.block.move", { blockId: block.blockId, afterBlockId: block.beforePreviousId })
            }

            ShellButton {
                objectName: "spaceMoveDown:" + block.text
                subtle: true
                iconName: "arrow-down"
                implicitHeight: 26
                implicitWidth: 26
                Accessible.name: qsTr("Move down")
                visible: !block.readOnly
                enabled: block.nextId !== ""
                onClicked: Shell.dispatch("space.block.move", { blockId: block.blockId, afterBlockId: block.nextId })
            }

            ShellButton {
                objectName: "spaceDeleteBlock:" + block.text
                subtle: true
                iconName: "x"
                implicitHeight: 26
                implicitWidth: 26
                Accessible.name: qsTr("Delete block")
                visible: !block.readOnly
                onClicked: Shell.dispatch("space.block.delete", { blockId: block.blockId })
            }
        }
    }
}
