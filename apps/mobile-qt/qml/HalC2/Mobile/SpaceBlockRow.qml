pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// One block of the open page in the phone layout. Its text is drawn as Markdown
// (the chat's Markdown brick, untrusted); a tap on a link opens it, and a tap
// anywhere else edits its source where it is, which goes to the MC when the
// editor loses focus and is drawn again. A checklist item is ticked
// by its box, a link opens its page and an image shows above its caption. Moving,
// deleting and commenting are in the menu at its end, where a desktop's hover would
// have them. A chart is not written in: it is drawn, and asked for again from the menu.
// A raw block is Markdown the page keeps as written: shown and edited as its source,
// in a fixed-width face, line for line, scrolled sideways rather than wrapped. A table
// and a code block show so too until they are drawn as such (#854), and a block the
// page does not draw yet shows what the MC writes around its text (a list item's
// marker, an alert's kind, a divider, a footnote's label, a section's tags, math's
// fences and an image's address, #869 and #877). A "mermaid" code
// block, or a raw block that is one "mermaid" fence, is drawn as its diagram instead,
// with its source a tap away, and says under the source why when it can't be drawn.
Rectangle {
    id: row

    required property var model
    required property int index
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
    // The controller selects a page before the user opens it: no bytes until then.
    property bool onScreen: true
    // A page in the trash is only read.
    property bool readOnly: false
    readonly property string blockId: model.id
    // What a chart block draws; empty on the others.
    readonly property var chart: model.chart ?? ({})
    // A heading's level, 1 to 6.
    readonly property int level: model.level ?? 2
    // A code block's language ("" for none).
    readonly property string language: model.language ?? ""
    readonly property bool raw: kind === "raw" || kind === "table" || kind === "code"
    // The Markdown the MC writes above, before, after and below the text (SpaceController).
    readonly property string markdownAbove: model.markdownAbove ?? ""
    readonly property string markdownLead: model.markdownLead ?? ""
    readonly property string markdownTail: model.markdownTail ?? ""
    readonly property string markdownBelow: model.markdownBelow ?? ""
    readonly property string mono: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
    // The source editor: made while the user edits a drawn block, and always
    // for a block that is shown as its source.
    readonly property TextEdit editor: editorLoader.item as TextEdit
    readonly property bool editing: editor !== null && editor.activeFocus
    // The Mermaid source a "mermaid" code block holds, or a raw block's fence, or "":
    // drawn in place of the text until the user switches to the source, and what
    // they write there once it is saved.
    readonly property string diagramCode: kind === "code" ? (language.toLowerCase() === "mermaid" ? text : "")
                                        : kind === "raw" ? mermaidOf(text) : ""
    property bool diagramSource: false
    readonly property bool diagramShown: diagramCode.length > 0 && diagram.drawn && !diagramSource
    // The block shows text: a link, a chart, what an update wrote, a divider,
    // a section's end and a drawn diagram show something else.
    readonly property bool textShown: !diagramShown && ["subpage_link", "chart", "generated", "divider", "details_end"].indexOf(kind) < 0
    // Text drawn as Markdown while it is not edited (as the desktop's SpaceBlock
    // draws it): raw, table and code blocks are their source, and an image's
    // caption and a section's summary sit between Markdown the MC writes on their line.
    readonly property bool drawn: textShown && !raw && kind !== "details" && kind !== "image"
    // The user is writing in a drawn block: its source shows.
    property bool sourceShown: false

    signal menuRequested
    signal linkOpened
    signal commentsRequested

    // The source of the one fenced "mermaid" block `text` is, or "" (as the
    // desktop's SpaceBlock reads it).
    function mermaidOf(text) {
        const fence = /^ {0,3}(`{3,}|~{3,})[ \t]*mermaid[ \t]*\r?\n([\s\S]*?)\r?\n {0,3}\1[`~]*[ \t]*(?:\r?\n)?$/i.exec(text);
        return fence ? fence[2] : "";
    }

    function commit() {
        if (editor !== null && kind !== "subpage_link" && kind !== "chart" && kind !== "generated" && editor.text !== text)
            Shell.dispatch("space.block.update", { blockId: blockId, text: editor.text });
    }

    // Shows a drawn block's source to edit, the caret near (x, y) in the drawn
    // text, or at its end with no point.
    function edit(x, y) {
        sourceShown = true;
        editor.forceActiveFocus();
        if (x === undefined) {
            editor.cursorPosition = editor.length;
        } else {
            const at = editor.mapFromItem(drawnLoader, x, y);
            editor.cursorPosition = editor.positionAt(at.x, at.y);
        }
    }

    // What the MC wrote shows, and a diagram is drawn again, unless the user is
    // writing here.
    onTextChanged: {
        // The editor's focus, not `editing`: a write it makes as it loses
        // the keyboard lands before that follows.
        if (editor !== null && editor.activeFocus)
            return;
        if (editor !== null)
            editor.text = text;
        diagramSource = false;
    }
    // Scrolled away or the screen left mid-edit: what was written still counts.
    Component.onDestruction: commit()

    implicitHeight: Math.max(52, content.implicitHeight + 8)
    color: kind === "callout" ? Qt.alpha(Theme.palette.color("info", "#3b82f6"), Theme.appearance === "dark" ? 0.14 : 0.08) : "transparent"
    objectName: "spaceBlock:" + text

    RowLayout {
        id: content

        anchors.fill: parent
        anchors.leftMargin: row.kind === "checklist" ? 4 : 16
        anchors.rightMargin: 4
        spacing: 4

        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: 2

            // Its height follows its width, which a layout would write over.
            Item {
                Layout.fillWidth: true
                Layout.topMargin: 8
                Layout.preferredHeight: picture.height
                // An image by its address is never fetched: its caption and address show instead.
                visible: row.kind === "image" && row.imageId.length > 0

                SpaceBlockImage {
                    id: picture

                    objectName: "spaceBlockImage:" + row.text
                    width: parent.width
                    imageId: row.imageId
                    state_: row.imageState
                    url: row.onScreen ? row.imageUrl : ""
                    naturalWidth: row.imageWidth
                    naturalHeight: row.imageHeight
                    readOnly: row.readOnly
                }
            }

            Label {
                objectName: "spaceMarkdownAbove:" + row.text
                visible: row.markdownAbove.length > 0 && source.visible
                text: row.markdownAbove
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.family: row.mono
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.features: { "liga": 0, "calt": 0 }
            }

            // The text, and what the MC writes before and after it on its line.
            RowLayout {
                id: source

                Layout.fillWidth: true
                visible: row.kind !== "subpage_link" && row.kind !== "chart" && row.kind !== "generated" && !row.diagramShown
                spacing: 4

                // Under the line above, as the MC writes it: a section's summary under its tag.
                Label {
                    objectName: "spaceMarkdownLead:" + row.text
                    visible: row.markdownLead.length > 0
                    text: row.markdownLead
                    color: Theme.palette.color("textMuted", "#a1a1aa")
                    font.family: row.mono
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                    font.features: { "liga": 0, "calt": 0 }
                }

                CheckBox {
                    objectName: "spaceTick:" + row.text
                    visible: row.kind === "checklist"
                    enabled: !row.readOnly
                    checked: row.checked
                    Accessible.name: row.text
                    onToggled: {
                        Shell.dispatch("space.block.setChecked", { blockId: row.blockId, checked: checked });
                        checked = Qt.binding(() => row.checked);
                    }
                }

                // A raw block's lines keep their length: it scrolls sideways, the others wrap.
                Flickable {
                    id: scroller

                    Layout.fillWidth: true
                    // A divider and a section's end have no text: their Markdown is all they show.
                    visible: row.textShown
                    // Up to its text's width when something follows it on its line.
                    Layout.maximumWidth: row.markdownTail.length > 0 ? Math.max(40, (row.editor?.implicitWidth ?? 0) + 2) : Number.POSITIVE_INFINITY
                    Layout.preferredHeight: contentHeight
                    contentWidth: row.editor !== null ? editorLoader.width : width
                    contentHeight: row.editor !== null ? editorLoader.height : drawnLoader.height
                    flickableDirection: Flickable.HorizontalFlick
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: contentWidth > width
                    clip: row.raw

                    // The text drawn, at its size and with its tick's strikeout: a tap
                    // on a link opens it, anywhere else edits the source, as a
                    // keyboard's focus does.
                    Loader {
                        id: drawnLoader

                        active: row.drawn
                        visible: row.editor === null
                        width: scroller.width

                        sourceComponent: FocusScope {
                            height: Math.max(drawnText.implicitHeight, 24)
                            activeFocusOnTab: true
                            Accessible.role: Accessible.EditableText
                            Accessible.name: qsTr("Block text")
                            onActiveFocusChanged: {
                                if (activeFocus)
                                    row.edit();
                            }

                            Markdown {
                                id: drawnText

                                objectName: "spaceBlockText:" + row.text
                                width: parent.width
                                selectable: false
                                text: row.text
                                textColor: Theme.palette.color("text", "#e4e4e7")
                                fontSize: Math.round((row.kind === "heading" ? [24, 20, 18, 17, 16, 15][Math.min(Math.max(row.level, 1), 6) - 1] : 15) * Theme.fontScale)
                                fontWeight: row.kind === "heading" ? Font.DemiBold : Font.Normal
                                struck: row.kind === "checklist" && row.checked
                                opacity: row.kind === "checklist" && row.checked ? 0.6 : 1
                            }

                            TapHandler {
                                onTapped: eventPoint => {
                                    const link = drawnText.linkAt(eventPoint.position.x, eventPoint.position.y);
                                    if (link.length > 0)
                                        Shell.openExternal(link);
                                    else
                                        row.edit(eventPoint.position.x, eventPoint.position.y);
                                }
                            }
                        }
                    }

                    Loader {
                        id: editorLoader

                        // A diagram keeps its source while it is drawn, a tap away.
                        active: (row.textShown || row.diagramCode.length > 0) && (!row.drawn || row.sourceShown)
                        sourceComponent: editorComponent
                    }

                    Component {
                        id: editorComponent

                        TextEdit {
                            id: sourceEditor

                            objectName: "spaceBlockEditor:" + row.text
                            width: row.raw ? Math.max(scroller.width, implicitWidth) : scroller.width
                            readOnly: row.readOnly
                            textFormat: TextEdit.PlainText
                            wrapMode: row.raw ? TextEdit.NoWrap : TextEdit.Wrap
                            color: Theme.palette.color("text", "#e4e4e7")
                            selectionColor: Theme.palette.color("accent", "#2563eb")
                            opacity: row.kind === "checklist" && row.checked ? 0.6 : 1
                            font.family: row.raw ? (Theme.fontMono.length > 0 ? Theme.fontMono : "monospace") : Application.font.family
                            // A second-level heading is the usual one; a first is larger and the rest step down.
                            font.pixelSize: Math.round((row.kind === "heading" ? [24, 20, 18, 17, 16, 15][Math.min(Math.max(row.level, 1), 6) - 1] : row.raw ? 13 : 15) * Theme.fontScale)
                            font.weight: row.kind === "heading" ? Font.DemiBold : Font.Normal
                            font.strikeout: row.kind === "checklist" && row.checked
                            Accessible.name: qsTr("Block text")
                            Component.onCompleted: text = row.text
                            // Leaving it writes it, and a drawn block is drawn again.
                            onActiveFocusChanged: {
                                if (activeFocus)
                                    return;
                                row.commit();
                                text = row.text;
                                row.sourceShown = false;
                            }
                            // Typing in raw Markdown past the edge brings the cursor back into view.
                            onCursorRectangleChanged: {
                                if (!row.raw || !activeFocus)
                                    return;
                                if (cursorRectangle.x < scroller.contentX)
                                    scroller.contentX = cursorRectangle.x;
                                else if (cursorRectangle.x + cursorRectangle.width > scroller.contentX + scroller.width)
                                    scroller.contentX = cursorRectangle.x + cursorRectangle.width - scroller.width;
                            }
                            // A heading or a checklist item is one line.
                            Keys.onReturnPressed: event => {
                                if (row.kind === "heading" || row.kind === "checklist")
                                    sourceEditor.focus = false;
                                else
                                    event.accepted = false;
                            }
                        }
                    }
                }

                Label {
                    objectName: "spaceMarkdownTail:" + row.text
                    visible: row.markdownTail.length > 0
                    text: row.markdownTail
                    color: Theme.palette.color("textMuted", "#a1a1aa")
                    font.family: row.mono
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                    font.features: { "liga": 0, "calt": 0 }
                }

                Item {
                    Layout.fillWidth: true
                    visible: row.markdownTail.length > 0 || !scroller.visible
                }
            }

            Label {
                objectName: "spaceMarkdownBelow:" + row.text
                visible: row.markdownBelow.length > 0 && source.visible
                text: row.markdownBelow
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.family: row.mono
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.features: { "liga": 0, "calt": 0 }
            }

            // The diagram in place of its source, or why it isn't drawn under it.
            MermaidDiagram {
                id: diagram

                objectName: "spaceDiagram:" + row.text
                Layout.fillWidth: true
                Layout.preferredHeight: implicitHeight
                visible: row.diagramCode.length > 0 && !row.diagramSource
                active: row.onScreen && row.diagramCode.length > 0
                code: row.diagramCode
                padding: 0
            }

            // What a page's update wrote: Markdown nobody edits by hand.
            Loader {
                Layout.fillWidth: true
                active: row.kind === "generated"
                visible: active

                sourceComponent: ColumnLayout {
                    spacing: 2

                    Markdown {
                        objectName: "spaceGenerated"
                        Layout.fillWidth: true
                        text: row.text
                    }

                    Label {
                        text: qsTr("Written by this page's update")
                        color: Theme.palette.color("textMuted", "#a1a1aa")
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }
                }
            }

            Loader {
                Layout.fillWidth: true
                Layout.topMargin: 6
                active: row.kind === "chart"
                visible: active

                sourceComponent: SpaceChart {
                    chart: row.chart
                }
            }

            MobileButton {
                objectName: "spaceLink:" + row.linkedTitle
                visible: row.kind === "subpage_link"
                subtle: true
                text: row.linkedTitle
                onClicked: row.linkOpened()
            }

            Label {
                visible: row.byAgent
                text: qsTr("agent")
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }
        }

        MobileButton {
            objectName: "spaceComment:" + row.text
            visible: row.openComments > 0
            subtle: true
            text: row.openComments
            Accessible.name: qsTr("%n open comment(s)", "", row.openComments)
            onClicked: row.commentsRequested()
        }

        MobileIconButton {
            objectName: "spaceDiagramSource:" + row.text
            Layout.alignment: Qt.AlignTop
            visible: row.diagramCode.length > 0 && diagram.drawn
            iconName: row.diagramSource ? "image" : "code"
            label: row.diagramSource ? qsTr("Show the diagram") : qsTr("Show the source")
            onClicked: row.diagramSource = !row.diagramSource
        }

        MobileIconButton {
            objectName: "spaceBlockMenu:" + row.text
            Layout.alignment: row.kind === "chart" || row.diagramShown ? Qt.AlignTop : Qt.AlignVCenter
            visible: !row.readOnly
            iconName: "ellipsis"
            label: qsTr("Actions for this block")
            onClicked: row.menuRequested()
        }
    }
}
