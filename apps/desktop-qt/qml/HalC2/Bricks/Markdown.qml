import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell
import "js/markdown.js" as Md

// Chat markdown in the web app's `.chat-markdown` look (ChatMarkdown.tsx and
// index.css). The text is untrusted and js/markdown.js escapes all of it; this
// brick draws its segments: prose as rich text (one selection runs across a
// segment), code blocks with a header, copy and wrap toggle, tables with
// expand and copy, and quotes with their rule. `streaming` keeps each block
// its own segment so a delta re-lays out only the last one.
Item {
    id: root

    property string text: ""
    property bool streaming: false
    // User messages keep their line breaks (the web's `lineBreaks`).
    property bool lineBreaks: false
    property color textColor: Qt.alpha(Theme.palette.color("text", "#f5f5f5"), 0.8)

    // An assistant reply offers "Cite" on a selection (AssistantSelectionToolbar).
    property bool citable: false
    // The brick this one is a quote of, which cites for it.
    property Item host: null
    // The text with the selection, when one has it.
    property Item selection: null

    signal linkActivated(string link)
    // The selection to quote in the composer: {text, start, end, prefix,
    // suffix}, an AssistantCitation's selector over the reply as drawn.
    signal cited(var selector)

    readonly property color headingColor: Theme.palette.color("text", "#f5f5f5")
    readonly property color mutedColor: Theme.palette.color("textMuted", "#818181")
    readonly property color borderColor: Theme.palette.color("border", "#191919")
    readonly property color selectionColor: Qt.alpha(Theme.palette.color("accent", "#346bf1"), 0.4)
    readonly property string uiFamily: Theme.fontUi.length > 0 ? Theme.fontUi : Qt.application.font.family
    readonly property string monoFamily: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
    readonly property bool light: Theme.appearance === "light"
    readonly property int codeSize: {
        Settings.device;
        Settings.document;
        return Settings.setting("fontSizeCode") ?? 13;
    }
    // The head every rich text segment carries; a theme change restyles the
    // segments without parsing the reply again.
    readonly property string styleHead: Md.styleHead({
        link: css(Theme.link),
        heading: css(headingColor),
        muted: css(mutedColor),
        // The web's inline code is a muted pill with a border; rich text
        // has neither border nor radius, so the fill carries the border.
        codeFill: css(Qt.tint(Theme.palette.color("muted", "#111111"), Qt.alpha(borderColor, 0.7))),
        mono: monoFamily,
        rule: css(borderColor)
    })

    // The segments in view, for tests and the brick's own sizing.
    readonly property alias segmentCount: segmentModel.count

    // With fitWidth the brick's implicitWidth is its widest segment's
    // natural width, for a bubble that shrinks to its text; it costs an
    // unwrapped layout of every segment, so only bubbles ask for it.
    property bool fitWidth: false
    property real naturalWidth: 0

    implicitHeight: column.implicitHeight
    implicitWidth: naturalWidth

    function css(c) {
        return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + c.a.toFixed(3) + ")";
    }

    function rich(html) {
        return "<html><head>" + styleHead + "</head><body>" + html + "</body></html>";
    }

    // Every text of the reply, in reading order.
    function texts() {
        let all = [];
        for (let i = 0; i < segments.count; ++i) {
            const item = segments.itemAt(i);
            if (item && typeof item.texts === "function")
                all = all.concat(item.texts());
        }
        return all;
    }

    function track(edit) {
        if (edit.selectedText.length > 0)
            selection = edit;
        else if (selection === edit)
            selection = null;
    }

    // Cites `edit`'s selection, placed in the whole reply's text.
    function cite(edit) {
        if (host) {
            host.cite(edit);
            return;
        }
        const plain = item => item.getText(0, item.length).replace(/[\u2028\u2029]/g, "\n");
        const all = texts();
        const at = all.indexOf(edit);
        if (at < 0)
            return;
        const before = all.slice(0, at).map(plain).join("\n");
        const offset = before.length + (at > 0 ? 1 : 0);
        const selector = Md.selector(all.map(plain).join("\n"), offset + edit.selectionStart, offset + edit.selectionEnd);
        edit.deselect();
        if (selector)
            cited(selector);
    }

    // Puts plain text on the clipboard.
    function copyText(value) {
        clipboard.text = value;
        clipboard.selectAll();
        clipboard.copy();
        clipboard.text = "";
    }

    function measure() {
        let width = 0;
        for (let i = 0; i < segments.count; ++i) {
            const item = segments.itemAt(i);
            // A delegate on its way out has lost its functions.
            if (item && typeof item.naturalWidth === "function")
                width = Math.max(width, item.naturalWidth());
        }
        naturalWidth = Math.ceil(width);
    }

    // Brings the model in line with the parsed segments: unchanged segments
    // keep their items untouched, a changed one gets only the roles that
    // differ, and a segment that changes kind is rebuilt.
    function sync() {
        const next = Md.segments(text, { streaming: streaming, lineBreaks: lineBreaks });
        const roles = ["html", "code", "language", "title", "open", "indent", "payload", "alert", "gap"];
        for (let i = 0; i < next.length; ++i) {
            const segment = next[i];
            if (i >= segmentModel.count) {
                segmentModel.append(segment);
                continue;
            }
            const current = segmentModel.get(i);
            if (current.kind !== segment.kind) {
                segmentModel.set(i, segment);
                continue;
            }
            for (const role of roles) {
                if (current[role] !== segment[role])
                    segmentModel.setProperty(i, role, segment[role]);
            }
        }
        if (segmentModel.count > next.length) {
            segmentModel.remove(next.length, segmentModel.count - next.length);
            if (fitWidth)
                Qt.callLater(measure);
        }
        // New segments are laid out already: a bubble fits them before it
        // is first drawn.
        if (fitWidth)
            measure();
    }

    onTextChanged: sync()
    onStreamingChanged: sync()
    onLineBreaksChanged: sync()
    Component.onCompleted: sync()

    ListModel {
        id: segmentModel
    }

    TextEdit {
        id: clipboard
        visible: false
        textFormat: TextEdit.PlainText
    }

    // A 24px icon button in the web's `icon-xs` size: ghost-muted, or
    // secondary while `checked`.
    component IconButton: ShellButton {
        property string label: ""
        subtle: true
        implicitWidth: 24
        implicitHeight: 24
        iconSize: 12
        radius: 6
        tint: checked ? root.headingColor : root.mutedColor
        focusPolicy: Qt.TabFocus
        Accessible.name: label
        ToolTip.visible: hovered && label.length > 0
        ToolTip.text: label
        ToolTip.delay: 400
    }

    // Rich text the reader can select, with links that open through the
    // brick and show where they go.
    component RichText: TextEdit {
        textFormat: TextEdit.RichText
        wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
        readOnly: true
        selectByMouse: true
        selectionColor: root.selectionColor
        color: root.textColor
        font.family: root.uiFamily
        font.pixelSize: 14
        onLinkActivated: link => root.linkActivated(link)
        onSelectedTextChanged: root.track(this)
        function texts() {
            return [this];
        }
        ToolTip.visible: hoveredLink.length > 0
        ToolTip.text: hoveredLink
        ToolTip.delay: 600
        HoverHandler {
            cursorShape: parent.hoveredLink.length > 0 ? Qt.PointingHandCursor : Qt.IBeamCursor
        }
    }

    // Horizontal scrolling for code and tables: the wheel's sideways axis or
    // shift, and a thin bar; flicking is for touch, so a mouse drag selects.
    component SideScroll: Flickable {
        id: flick
        clip: true
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        interactive: Qt.platform.os === "android" || Qt.platform.os === "ios"
        contentHeight: height
        ScrollBar.horizontal: ScrollBar {
            height: 7
            policy: flick.contentWidth > flick.width + 0.5 ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
            contentItem: Rectangle {
                implicitHeight: 7
                radius: 3.5
                color: Qt.alpha(root.borderColor, 0.78)
            }
            background: Item {}
        }
        MouseArea {
            parent: flick
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            onWheel: wheel => {
                const dx = wheel.angleDelta.x !== 0 ? wheel.angleDelta.x : (wheel.modifiers & Qt.ShiftModifier) ? wheel.angleDelta.y : 0;
                if (dx === 0 || flick.contentWidth <= flick.width) {
                    wheel.accepted = false;
                    return;
                }
                flick.contentX = Math.max(0, Math.min(flick.contentWidth - flick.width, flick.contentX - dx));
            }
        }
    }

    // "Cite" under the selection's last line, or over it at the brick's foot
    // when there is a line above to sit on (AssistantSelectionToolbar). It
    // takes no focus: the selection stays.
    ShellButton {
        id: citeButton
        objectName: "citeSelection"

        readonly property bool tooLong: root.selection !== null && root.selection.selectedText.length > 8000
        readonly property rect end: {
            const edit = root.selection;
            if (edit === null)
                return Qt.rect(0, 0, 0, 0);
            edit.width;
            root.width;
            const caret = edit.positionToRectangle(edit.selectionEnd);
            const at = root.mapFromItem(edit, caret.x, caret.y);
            return Qt.rect(at.x, at.y, caret.width, caret.height);
        }

        visible: root.citable && root.selection !== null
        z: 1
        x: Math.max(0, Math.min(end.x, root.width - width))
        y: end.y + end.height + 4 + height <= root.height || end.y - height - 4 < 0 ? end.y + end.height + 4 : end.y - height - 4
        implicitHeight: 24
        iconName: "quote"
        iconSize: 12
        font.pixelSize: 12
        focusPolicy: Qt.NoFocus
        enabled: !tooLong
        text: tooLong ? qsTr("Shorten selection") : qsTr("Cite")
        Accessible.name: tooLong ? qsTr("Selection is too long to cite") : qsTr("Cite selection in composer")
        onClicked: root.cite(root.selection)

        // The outline button is see-through; this one floats over text.
        Rectangle {
            z: -2
            anchors.fill: parent
            radius: citeButton.radius
            color: Theme.palette.color("surfaceOverlay", "#18181b")
        }
    }

    Column {
        id: column
        width: root.width

        Repeater {
            id: segments
            model: segmentModel

            delegate: Item {
                id: seg

                required property int index
                required property string kind
                required property string html
                required property string code
                required property string language
                required property string title
                required property bool open
                required property real indent
                required property string payload
                required property string alert
                required property real gap

                function naturalWidth() {
                    return loader.item ? loader.item.implicitWidth + indent : 0;
                }

                function texts() {
                    return loader.item && typeof loader.item.texts === "function" ? loader.item.texts() : [];
                }

                objectName: "markdownSegment"
                width: column.width
                height: gap + loader.height
                Connections {
                    target: root.fitWidth ? loader.item : null
                    function onImplicitWidthChanged() {
                        Qt.callLater(root.measure);
                    }
                }

                Loader {
                    id: loader
                    x: seg.indent
                    y: seg.gap
                    width: seg.width - seg.indent
                    height: item ? item.implicitHeight : 0
                    onLoaded: {
                        if (root.fitWidth)
                            Qt.callLater(root.measure);
                    }
                    sourceComponent: seg.kind === "code" ? codeBlock : seg.kind === "table" ? table : seg.kind === "quote" ? quote : prose
                }

                Component {
                    id: prose
                    RichText {
                        objectName: "markdownProse"
                        text: root.rich(seg.html)
                    }
                }

                Component {
                    id: codeBlock
                    Rectangle {
                        id: block
                        objectName: "markdownCode"

                        property bool wrapped: Settings.setting("wordWrap") ?? true
                        property bool copied: false
                        readonly property real lineHeight: Math.round(root.codeSize * 1.375 * 10) / 10
                        readonly property string code: seg.code

                        function texts() {
                            return [codeText];
                        }

                        function copy() {
                            root.copyText(seg.code);
                            copied = true;
                            copiedTimer.restart();
                        }

                        implicitWidth: codeText.implicitWidth + 28.8
                        implicitHeight: 30 + body.height
                        radius: Theme.radius
                        color: Theme.palette.color("codeBackground", "#111111")
                        border.color: root.borderColor
                        border.width: 1

                        Timer {
                            id: copiedTimer
                            interval: 1200
                            onTriggered: block.copied = false
                        }

                        Row {
                            x: 12
                            y: 6
                            height: 24
                            width: actions.x - 12 - 8
                            spacing: 5.6
                            ShellIcon {
                                visible: seg.title.length > 0
                                anchors.verticalCenter: parent.verticalCenter
                                name: "file"
                                size: 14
                                color: label.color
                            }
                            Text {
                                id: label
                                objectName: "codeLabel"
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - (seg.title.length > 0 ? 19.6 : 0)
                                text: seg.title.length > 0 ? seg.title : seg.language.length > 0 ? seg.language : "text"
                                elide: Text.ElideRight
                                font.family: root.monoFamily
                                font.pixelSize: 11
                                color: Qt.alpha(Theme.palette.color("codeForeground", "#f5f5f5"), 0.72)
                            }
                        }

                        Row {
                            id: actions
                            anchors.right: parent.right
                            anchors.rightMargin: 6
                            y: 6
                            spacing: 2
                            IconButton {
                                objectName: "wrapCode"
                                iconName: "text-wrap"
                                checked: block.wrapped
                                label: block.wrapped ? qsTr("Disable line wrap") : qsTr("Wrap lines")
                                onClicked: block.wrapped = !block.wrapped
                            }
                            IconButton {
                                objectName: "copyCode"
                                iconName: block.copied ? "check" : "copy"
                                label: block.copied ? qsTr("Copied") : qsTr("Copy code")
                                onClicked: block.copy()
                            }
                        }

                        SideScroll {
                            id: body
                            y: 30
                            width: parent.width
                            height: codeText.height + 25.6
                            contentWidth: codeText.width + 28.8

                            TextEdit {
                                id: codeText
                                objectName: "codeText"
                                x: 14.4
                                y: 12.8
                                width: block.wrapped ? body.width - 28.8 : Math.max(implicitWidth, body.width - 28.8)
                                textFormat: TextEdit.RichText
                                text: Md.codeHtml(seg.code, block.lineHeight)
                                wrapMode: block.wrapped ? TextEdit.WrapAtWordBoundaryOrAnywhere : TextEdit.NoWrap
                                readOnly: true
                                selectByMouse: true
                                selectionColor: root.selectionColor
                                onSelectedTextChanged: root.track(codeText)
                                color: Theme.palette.color("codeForeground", "#f5f5f5")
                                font.family: root.monoFamily
                                font.pixelSize: root.codeSize
                            }
                        }
                    }
                }

                Component {
                    id: table
                    Item {
                        id: grid
                        objectName: "markdownTable"

                        readonly property var spec: JSON.parse(seg.payload)
                        readonly property var rows: [spec.header].concat(spec.rows)
                        property bool expanded: Settings.setting("wordWrap") ?? true
                        property bool copied: false
                        property var widths: []
                        readonly property real naturalWidth: widths.reduce((sum, w) => sum + w, 0)
                        // Width 100%, at least max-content: spare room goes to
                        // the columns in proportion, as an auto table layout does.
                        readonly property real scale: naturalWidth > 0 && naturalWidth < width ? width / naturalWidth : 1

                        function copy(format) {
                            root.copyText(format === "csv" ? spec.csv : spec.markdown);
                            copied = true;
                            copiedTimer.restart();
                        }

                        // Each column is as wide as its widest cell, capped at
                        // 24rem (a header only while collapsed), plus padding.
                        function measure() {
                            const next = [];
                            for (let r = 0; r < lines.count; ++r) {
                                const line = lines.itemAt(r);
                                if (!line)
                                    continue;
                                for (let c = 0; c < line.cellCount; ++c) {
                                    const cell = line.cell(c);
                                    if (!cell)
                                        continue;
                                    const cap = r === 0 && expanded ? Infinity : 384;
                                    next[c] = Math.max(next[c] ?? 0, Math.min(Math.ceil(cell.implicitWidth), cap) + 24);
                                }
                            }
                            widths = next;
                        }

                        function texts() {
                            const all = [];
                            for (let r = 0; r < lines.count; ++r) {
                                const line = lines.itemAt(r);
                                for (let c = 0; line && c < line.cellCount; ++c) {
                                    if (line.cell(c))
                                        all.push(line.cell(c));
                                }
                            }
                            return all;
                        }

                        implicitWidth: naturalWidth
                        implicitHeight: footer.y + footer.height
                        onExpandedChanged: Qt.callLater(measure)
                        Component.onCompleted: Qt.callLater(measure)

                        Timer {
                            id: copiedTimer
                            interval: 1200
                            onTriggered: grid.copied = false
                        }

                        SideScroll {
                            id: tableScroll
                            width: grid.width
                            height: tableBody.height
                            contentWidth: grid.naturalWidth * grid.scale

                            Column {
                                id: tableBody
                                Repeater {
                                    id: lines
                                    model: grid.rows
                                    delegate: Item {
                                        id: line
                                        required property var modelData
                                        required property int index
                                        readonly property bool head: index === 0
                                        readonly property int cellCount: cells.count
                                        function cell(c) {
                                            const item = cells.itemAt(c);
                                            return item ? item.text : null;
                                        }
                                        width: tableScroll.contentWidth
                                        height: cellRow.height + 1
                                        Row {
                                            id: cellRow
                                            Repeater {
                                                id: cells
                                                model: line.modelData
                                                delegate: Item {
                                                    required property string modelData
                                                    required property int index
                                                    readonly property alias text: cellText
                                                    width: (grid.widths[index] ?? 0) * grid.scale
                                                    height: cellRow.rowHeight
                                                    clip: true
                                                    RichText {
                                                        id: cellText
                                                        objectName: "tableCell"
                                                        x: 12
                                                        y: line.head ? 8.8 : 7.2
                                                        width: parent.width - 24
                                                        wrapMode: grid.expanded && !line.head ? TextEdit.WrapAtWordBoundaryOrAnywhere : TextEdit.NoWrap
                                                        font.pixelSize: 12
                                                        font.weight: line.head ? Font.DemiBold : Font.Normal
                                                        text: root.rich("<p align=\"" + (grid.spec.align[index] ?? "left") + "\" style=\"margin:0;line-height:19.5px;-qt-line-height-type:minimum\">" + modelData + "</p>")
                                                        onImplicitWidthChanged: Qt.callLater(grid.measure)
                                                    }
                                                }
                                            }
                                            readonly property real rowHeight: {
                                                let h = 0;
                                                for (let c = 0; c < cells.count; ++c) {
                                                    const item = cells.itemAt(c);
                                                    if (item)
                                                        h = Math.max(h, grid.expanded && !line.head ? item.text.height : 19.5);
                                                }
                                                return h + (line.head ? 17.6 : 14.4);
                                            }
                                        }
                                        Rectangle {
                                            y: cellRow.height
                                            width: parent.width
                                            height: 1
                                            color: Qt.alpha(root.borderColor, root.borderColor.a * 0.6)
                                        }
                                    }
                                }
                            }
                        }

                        Item {
                            id: footer
                            y: tableScroll.height + 2
                            width: grid.width
                            height: 24
                            IconButton {
                                objectName: "expandTable"
                                iconName: grid.expanded ? "minimize-2" : "maximize-2"
                                checked: grid.expanded
                                label: grid.expanded ? qsTr("Collapse table cells") : qsTr("Expand table cells")
                                onClicked: grid.expanded = !grid.expanded
                            }
                            IconButton {
                                id: copyTableButton
                                objectName: "copyTable"
                                anchors.right: parent.right
                                iconName: grid.copied ? "check" : "copy"
                                label: grid.copied ? qsTr("Copied") : qsTr("Copy table")
                                onClicked: copyMenu.popup(copyTableButton, 0, copyTableButton.height)
                            }
                            ShellMenu {
                                id: copyMenu
                                objectName: "copyTableMenu"
                                ShellMenuItem {
                                    objectName: "copyTableMarkdown"
                                    text: qsTr("Copy as Markdown")
                                    onTriggered: grid.copy("markdown")
                                }
                                ShellMenuItem {
                                    objectName: "copyTableCsv"
                                    text: qsTr("Copy as CSV")
                                    onTriggered: grid.copy("csv")
                                }
                            }
                        }
                    }
                }

                Component {
                    id: quote
                    Item {
                        id: quoteBox
                        objectName: "markdownQuote"

                        // GitHub's alert kinds: label, icon, and the title and
                        // rule colours (tailwind 600 on light, 400 on dark).
                        readonly property var kinds: ({
                            note: ["Note", "info", "#3b82f6", "#2563eb", "#60a5fa"],
                            tip: ["Tip", "lightbulb", "#10b981", "#059669", "#34d399"],
                            important: ["Important", "message-square-warning", "#a855f7", "#9333ea", "#c084fc"],
                            warning: ["Warning", "triangle-alert", "#f59e0b", "#d97706", "#f59e0b"],
                            caution: ["Caution", "octagon-alert", "#ef4444", "#dc2626", "#f87171"]
                        })
                        readonly property var kindOf: kinds[seg.alert] ?? null
                        readonly property color titleColor: kindOf ? (root.light ? kindOf[3] : kindOf[4]) : root.textColor

                        implicitWidth: (inner.item ? inner.item.implicitWidth : 0) + inner.x
                        implicitHeight: inner.y + inner.height

                        Rectangle {
                            width: 2
                            height: parent.height
                            color: quoteBox.kindOf ? Qt.alpha(quoteBox.kindOf[2], 0.7) : root.borderColor
                        }

                        Row {
                            id: alertTitle
                            visible: quoteBox.kindOf !== null
                            x: 12
                            height: visible ? 23 : 0
                            spacing: 6
                            ShellIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: quoteBox.kindOf ? quoteBox.kindOf[1] : ""
                                size: 14
                                color: quoteBox.titleColor
                            }
                            Text {
                                objectName: "alertTitle"
                                anchors.verticalCenter: parent.verticalCenter
                                text: quoteBox.kindOf ? qsTr(quoteBox.kindOf[0]) : ""
                                color: quoteBox.titleColor
                                font.family: root.uiFamily
                                font.pixelSize: 14
                                font.weight: Font.Medium
                            }
                        }

                        Loader {
                            id: inner
                            x: quoteBox.kindOf ? 12 : 12.8
                            y: quoteBox.kindOf ? alertTitle.height + 10.4 : 0
                            width: parent.width - x
                            height: item ? item.implicitHeight : 0
                            source: Qt.resolvedUrl("Markdown.qml")
                            onLoaded: {
                                item.fitWidth = Qt.binding(() => root.fitWidth);
                                item.text = Qt.binding(() => seg.payload);
                                item.lineBreaks = Qt.binding(() => root.lineBreaks);
                                // A quote reads muted; an alert's body is ordinary text.
                                item.textColor = Qt.binding(() => quoteBox.kindOf ? root.textColor : root.mutedColor);
                                item.linkActivated.connect(root.linkActivated);
                                item.host = root;
                                item.citable = Qt.binding(() => root.citable);
                            }
                        }

                        function texts() {
                            return inner.item ? inner.item.texts() : [];
                        }
                    }
                }
            }
        }
    }
}
