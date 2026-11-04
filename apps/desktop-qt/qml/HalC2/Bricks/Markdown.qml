pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell
import "js/markdown.js" as Md

// Chat markdown. The text is untrusted and js/markdown.js escapes all of it; this
// brick draws its segments: prose as rich text (one selection runs across a
// segment), code blocks with a header, copy and wrap toggle, tables with
// expand and copy, and quotes with their rule. `streaming` keeps each block
// its own segment so a delta re-lays out only the last one, and a text that
// grows is parsed from its last unfinished block on, not from its start.
Item {
    id: root

    property string text: ""
    property bool streaming: false
    // User messages keep their line breaks.
    property bool lineBreaks: false
    // The text is the user's own file and not a reply: the task boxes the
    // Files viewer makes of its checklists (`task:<n>` links) are kept, to be
    // ticked. A reply must never have them, or it could tick a box in a file.
    property bool trusted: false
    property color textColor: Theme.palette.color("inkSecondary", "#b8bdc7")
    // The prose's font: a page's heading is larger, a ticked item struck out.
    property int fontSize: Theme.type.prose.size
    property int fontWeight: Font.Normal
    property bool struck: false
    // Off, prose is drawn as plain Text with no selection, menu or link
    // handling, for a page's hundreds of idle blocks whose owner edits on a
    // click and opens what linkAt finds.
    property bool selectable: true
    // The bulleted and numbered lists the text sits inside, for a page's list
    // item drawn on its own: its marker is the one its depth takes.
    property int bulletDepth: 0
    property int numberDepth: 0

    // An assistant reply offers "Cite" on a selection (AssistantSelectionToolbar).
    property bool citable: false
    // A reply offers "Run in terminal" on a code block that is one complete
    // shell command (Md.shellCommand), once it is no longer streaming.
    property bool runnable: false
    // The brick this one is a quote of, which cites for it.
    property Markdown host: null
    // The text with the selection, when one has it.
    property TextEdit selection: null

    // A pull request link's hover card and where a click on it goes
    // (Panel.linkPreviews, a PullRequestLinkPreviews); none shows the address.
    property var linkPreviews: null

    // external: the click held Shift as well, for the browser whatever the link.
    signal linkActivated(string link, bool external)
    // The selection to quote in the composer: {text, start, end, prefix,
    // suffix}, an AssistantCitation's selector over the reply as drawn.
    signal cited(var selector)
    // The user ran a code block's command (trimmed) from its Run.
    signal runCommand(string command)

    readonly property color headingColor: Theme.palette.color("ink", "#f2f3f5")
    readonly property color mutedColor: Theme.palette.color("textMuted", "#818181")
    readonly property color borderColor: Theme.palette.color("border", "#191919")
    readonly property color selectionColor: Qt.alpha(Theme.palette.color("accent", "#346bf1"), 0.4)
    readonly property string uiFamily: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
    readonly property string monoFamily: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
    readonly property bool light: Theme.appearance === "light"
    readonly property int codeSize: Theme.fontSizeCode
    // What the head of every rich text segment styles, by what it styles; a
    // theme change restyles the segments without parsing the reply again.
    readonly property var styleRules: Md.styleRules({
        link: css(Theme.link),
        heading: css(headingColor),
        muted: css(mutedColor),
        // Inline code is inset tinted with a tenth of the ink: rich text
        // has no border or radius, so the tint is all that marks it, and it
        // still does in a monospace shell, where code and prose share a font.
        codeFill: css(Qt.tint(Theme.palette.color("inset", "#0a0b0d"), Qt.alpha(headingColor, 0.1))),
        codeSize: Math.min(codeSize, fontSize),
        mono: monoFamily,
        rule: css(borderColor)
    })
    readonly property string styleHead: Md.styleHead(styleRules)

    // What opens every rich text, made once per theme and not per segment.
    readonly property string richHead: "<html><head>" + styleHead + "</head><body>"

    // What js/markdown.js keeps of this brick's text between deltas, made by
    // the first `sync` (which a binding may call before any other is set).
    property var reading: null

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
        return richHead + Md.inlineStyles(html, styleRules) + "</body></html>";
    }

    // A segment's item, whose functions are the delegate's own.
    function segmentAt(i: int): var {
        return segments.itemAt(i);
    }

    // Every text of the reply, in reading order.
    function texts() {
        let all = [];
        for (let i = 0; i < segments.count; ++i) {
            const item = segmentAt(i);
            if (item && typeof item.texts === "function")
                all = all.concat(item.texts());
        }
        return all;
    }

    // A quote's text is tracked by the reply it sits in, whose Cite and
    // `selection` are the ones the timeline sees.
    function track(edit) {
        if (host) {
            host.track(edit);
            return;
        }
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

    // Copy and Select All for `edit`'s text, at `position` in it. Made when
    // it opens: a menu for every reply would cost a long thread more than
    // its text.
    function openTextMenu(edit, position) {
        const menu = textMenu.createObject(root, {
            editor: edit
        });
        menu.openAt(position.x, position.y);
    }

    Component {
        id: textMenu

        TextEditMenu {
            id: menu

            objectName: "textMenu"
            onClosed: menu.destroy()
        }
    }

    // The link at (x, y) in the brick, or "".
    function linkAt(x: real, y: real): string {
        for (let i = 0; i < segments.count; ++i) {
            const item = segmentAt(i);
            if (!item || typeof item.linkAt !== "function")
                continue;
            const at = item.mapFromItem(root, x, y);
            if (at.y >= 0 && at.y < item.height)
                return item.linkAt(at.x, at.y);
        }
        return "";
    }

    // Whether (x, y) in the brick is on one of its own controls (a code
    // block's copy or wrap, a table's expand or copy), for an owner that
    // takes every other press itself, as a page's block does to edit it.
    function controlAt(x: real, y: real): bool {
        let item = root;
        let at = Qt.point(x, y);
        for (;;) {
            const child = item.childAt(at.x, at.y);
            if (child === null)
                return false;
            if (child instanceof ShellButton)
                return child.enabled;
            at = child.mapFromItem(item, at.x, at.y);
            item = child;
        }
    }

    // Puts plain text on the clipboard, through a TextEdit made on the first
    // copy: most bricks never copy.
    property TextEdit clipboard: null
    function copyText(value) {
        if (clipboard === null)
            clipboard = clipboardEdit.createObject(root);
        clipboard.text = value;
        clipboard.selectAll();
        clipboard.copy();
        clipboard.text = "";
    }

    function measure() {
        let width = 0;
        for (let i = 0; i < segments.count; ++i) {
            const item = segmentAt(i);
            // A delegate on its way out has lost its functions.
            if (item && typeof item.naturalWidth === "function")
                width = Math.max(width, item.naturalWidth());
        }
        naturalWidth = Math.ceil(width);
    }

    // Brings the model in line with the parsed segments: unchanged segments
    // keep their items untouched, a changed one gets only the roles that
    // differ, and a segment that changes kind is rebuilt. The segments before
    // `reading.stable` are the ones the model has, and are not looked at.
    function sync() {
        if (reading === null)
            reading = Md.state();
        const next = Md.segments(text, { streaming: streaming, lineBreaks: lineBreaks, tasks: trusted, ulDepth: bulletDepth, olDepth: numberDepth }, reading);
        const roles = ["html", "code", "language", "title", "open", "indent", "payload", "alert", "gap"];
        for (let i = Math.min(reading.stable, segmentModel.count); i < next.length; ++i) {
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
                measureLater.restart();
        }
        // New segments are laid out already: a bubble fits them before it
        // is first drawn.
        if (fitWidth)
            measure();
    }

    // A table's header, rows and alignments. A segment that becomes a table
    // is one for a moment before its payload is a table's: an empty one then.
    function tableSpec(payload) {
        try {
            return JSON.parse(payload);
        } catch (error) {
            return {
                header: [],
                rows: [],
                align: []
            };
        }
    }

    onTextChanged: sync()
    onStreamingChanged: sync()
    onLineBreaksChanged: sync()
    onTrustedChanged: sync()
    onBulletDepthChanged: sync()
    onNumberDepthChanged: sync()
    Component.onCompleted: sync()

    ListModel {
        id: segmentModel
    }

    // Measures on the next pass. A timer, not Qt.callLater: a quote's brick
    // dies when the stream turns the quote into another kind, and a call
    // queued on it would run on a destroyed context.
    Timer {
        id: measureLater
        interval: 0
        onTriggered: root.measure()
    }

    Component {
        id: clipboardEdit
        TextEdit {
            visible: false
            textFormat: TextEdit.PlainText
        }
    }

    // A 24px icon button: ghost-muted, or
    // secondary while `checked`.
    component IconButton: ShellButton {
        id: iconButton
        property string label: ""
        subtle: true
        implicitWidth: 24
        implicitHeight: 24
        iconSize: 12
        radius: Theme.radiusSm
        tint: iconButton.checked ? root.headingColor : root.mutedColor
        focusPolicy: Qt.TabFocus
        Accessible.name: iconButton.label
        ToolTip.visible: iconButton.hovered && iconButton.label.length > 0
        ToolTip.text: iconButton.label
        ToolTip.delay: 400
    }

    // Rich text the reader can select, with links that open through the
    // brick and show where they go. A plain click selects, so copying a
    // link never opens it: a link opens on a click with Ctrl (Cmd on macOS)
    // held, a finger's tap, or its menu. A task's box is a control, and
    // toggles on any click.
    component RichText: TextEdit {
        id: richText

        function follow(eventPoint, external) {
            const link = linkAt(eventPoint.position.x, eventPoint.position.y);
            if (link.length > 0 && !link.startsWith("task:"))
                root.linkActivated(link, external === true);
        }
        // The link under the pointer is a pull request the panel can read: its card shows instead.
        readonly property bool previewed: root.linkPreviews !== null && hoveredLink.length > 0 && root.linkPreviews.address === hoveredLink

        textFormat: TextEdit.RichText
        // TODO(ljos#159): Qt names a TextEdit by its text already; `ljos check` wants it said.
        // Its plain text, since `text` here is the HTML document.
        Accessible.name: getText(0, length)
        wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
        readOnly: true
        selectByMouse: true
        selectionColor: root.selectionColor
        color: root.textColor
        font.family: root.uiFamily
        font.pixelSize: root.fontSize
        font.weight: root.fontWeight
        font.strikeout: root.struck
        onLinkActivated: link => {
            if (link.startsWith("task:"))
                root.linkActivated(link, false);
        }
        onHoveredLinkChanged: {
            if (root.linkPreviews !== null)
                root.linkPreviews.hover(hoveredLink.startsWith("task:") ? "" : hoveredLink);
        }
        onSelectedTextChanged: root.track(this)
        // Qt's own copy would carry the word joiners inline code is drawn with.
        Keys.onPressed: event => {
            if (event.matches(StandardKey.Copy) && selectedText.length > 0) {
                root.copyText(Md.plain(selectedText));
                event.accepted = true;
            }
        }
        function texts() {
            return [this];
        }
        // Shown off its own text: bound to the link instead, it could open
        // with the previous link's text.
        ToolTip.visible: ToolTip.text.length > 0
        ToolTip.text: hoveredLink.length > 0 && !hoveredLink.startsWith("task:") && !previewed ? qsTr("%1\n%2-click to open").arg(hoveredLink).arg(Qt.platform.os === "osx" ? "⌘" : "Ctrl") : ""
        ToolTip.delay: 600
        TapHandler {
            acceptedButtons: Qt.LeftButton
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            acceptedModifiers: Qt.ControlModifier
            // ljos-allow(focus-pointer-only): a read-only TextEdit has no keyboard path to its links yet, hal-c2#574
            onTapped: eventPoint => richText.follow(eventPoint)
        }
        // Shift as well opens it in the browser, a pull request included.
        TapHandler {
            acceptedButtons: Qt.LeftButton
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            acceptedModifiers: Qt.ControlModifier | Qt.ShiftModifier
            // ljos-allow(focus-pointer-only): a read-only TextEdit has no keyboard path to its links yet, hal-c2#574
            onTapped: eventPoint => richText.follow(eventPoint, true)
        }
        HoverHandler {
            id: linkPointer
        }
        PullRequestLinkCard {
            previews: root.linkPreviews
            shown: richText.previewed
            address: richText.hoveredLink
            pointer: linkPointer.point.position
        }
        // Offers what can be done with the link under a point.
        function linkMenu(position, scenePosition) {
            const link = linkAt(position.x, position.y);
            if (link.length > 0) {
                Shell.dispatch("link.menu", {
                    url: link,
                    x: scenePosition.x,
                    y: scenePosition.y
                });
            }
        }
        // A finger follows a link with a tap, and holds it for its menu.
        TapHandler {
            id: touchLink
            acceptedDevices: PointerDevice.TouchScreen
            // ljos-allow(focus-pointer-only): a read-only TextEdit has no keyboard path to its links yet, hal-c2#574
            onTapped: eventPoint => richText.follow(eventPoint)
            onLongPressed: richText.linkMenu(touchLink.point.position, touchLink.point.scenePosition)
        }
        // The secondary button on a link offers what can be done with it,
        // and elsewhere copying the text (a finger has no buttons, and
        // would count as it).
        TapHandler {
            acceptedButtons: Qt.RightButton
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onTapped: eventPoint => {
                if (richText.linkAt(eventPoint.position.x, eventPoint.position.y).length > 0)
                    richText.linkMenu(eventPoint.position, eventPoint.scenePosition);
                else
                    root.openTextMenu(richText, eventPoint.position);
            }
        }
        HoverHandler {
            cursorShape: parent.hoveredLink.startsWith("task:") ? Qt.PointingHandCursor : Qt.IBeamCursor
        }
    }

    // Prose that is only drawn (`selectable` off). The Text sits in an item
    // the loader sizes, as a Text sized from outside lays itself out again.
    component DrawnText: Item {
        id: drawnItem

        property alias text: drawnLabel.text

        function linkAt(x: real, y: real): string {
            return drawnLabel.linkAt(x, y);
        }
        function texts() {
            return [];
        }

        implicitWidth: drawnLabel.implicitWidth
        implicitHeight: drawnLabel.implicitHeight

        Text {
            id: drawnLabel
            width: drawnItem.width
            textFormat: Text.RichText
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            color: root.textColor
            font.family: root.uiFamily
            font.pixelSize: root.fontSize
            font.weight: root.fontWeight
            font.strikeout: root.struck
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
            Accessible.name: qsTr("Scroll sideways")
            height: 7
            policy: flick.contentWidth > flick.width + 0.5 ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
            contentItem: Rectangle {
                implicitHeight: 7
                radius: Theme.radiusPill
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
    // takes no focus: the selection stays. Only a brick that can be
    // selected makes it.
    Loader {
        z: 1
        active: root.selectable
        sourceComponent: Component {
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
                font.pixelSize: Theme.type.meta.size
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

                // The loaded block, whose functions are its component's own.
                readonly property var block: loader.item

                function naturalWidth() {
                    return block ? block.implicitWidth + indent : 0;
                }

                function texts() {
                    return block && typeof block.texts === "function" ? block.texts() : [];
                }

                // Prose and quotes have links; code and tables are not looked in.
                function linkAt(x: real, y: real): string {
                    if (!block || typeof block.linkAt !== "function")
                        return "";
                    const at = block.mapFromItem(seg, x, y);
                    return block.linkAt(at.x, at.y);
                }

                objectName: "markdownSegment"
                width: column.width
                height: gap + loader.height
                Connections {
                    target: root.fitWidth ? loader.item : null
                    function onImplicitWidthChanged() {
                        measureLater.restart();
                    }
                }

                Loader {
                    id: loader
                    x: seg.indent
                    y: seg.gap
                    width: seg.width - seg.indent
                    height: (item as Item)?.implicitHeight ?? 0
                    onLoaded: {
                        if (root.fitWidth)
                            measureLater.restart();
                    }
                    sourceComponent: seg.kind === "code" ? codeBlock : seg.kind === "table" ? table : seg.kind === "quote" ? quote : root.selectable ? prose : drawnProse
                }

                Component {
                    id: prose
                    RichText {
                        objectName: "markdownProse"
                        text: root.rich(seg.html)
                    }
                }

                Component {
                    id: drawnProse
                    DrawnText {
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
                        // What its Run sends to the terminal; empty when it offers none.
                        readonly property string command: root.runnable && !root.streaming ? Md.shellCommand(seg) : ""
                        // A Mermaid block is drawn once its fence is closed; the
                        // user can switch back to its source.
                        readonly property bool mermaid: seg.language.toLowerCase() === "mermaid" && !seg.open
                        property bool showSource: false
                        readonly property bool picture: mermaid && diagram.drawn && !showSource

                        function texts() {
                            return [codeText];
                        }

                        function copy() {
                            root.copyText(seg.code);
                            copied = true;
                            copiedTimer.restart();
                        }

                        implicitWidth: picture ? diagram.implicitWidth : codeText.implicitWidth + 28.8
                        implicitHeight: 30 + content.height
                        radius: Theme.radiusMd
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
                                color: codeLabel.color
                            }
                            Text {
                                id: codeLabel
                                objectName: "codeLabel"
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - (seg.title.length > 0 ? 19.6 : 0)
                                text: seg.title.length > 0 ? seg.title : seg.language.length > 0 ? seg.language : "text"
                                elide: Text.ElideRight
                                font.family: root.monoFamily
                                font.pixelSize: Theme.type.caption.size
                                color: Theme.palette.color("inkSecondary", "#b8bdc7")
                            }
                        }

                        Row {
                            id: actions
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.space.sm
                            y: 6
                            spacing: 2
                            IconButton {
                                objectName: "diagramSource"
                                visible: block.mermaid && diagram.drawn
                                iconName: block.showSource ? "image" : "code"
                                label: block.showSource ? qsTr("Show the diagram") : qsTr("Show the source")
                                onClicked: block.showSource = !block.showSource
                            }
                            IconButton {
                                objectName: "wrapCode"
                                visible: !block.picture
                                iconName: "text-wrap"
                                checked: block.wrapped
                                label: block.wrapped ? qsTr("Disable line wrap") : qsTr("Wrap lines")
                                onClicked: block.wrapped = !block.wrapped
                            }
                            IconButton {
                                objectName: "runCode"
                                visible: block.command.length > 0
                                iconName: "play"
                                label: qsTr("Run in terminal")
                                onClicked: root.runCommand(block.command)
                            }
                            IconButton {
                                objectName: "copyCode"
                                iconName: block.copied ? "check" : "copy"
                                label: block.copied ? qsTr("Copied") : qsTr("Copy code")
                                onClicked: block.copy()
                            }
                        }

                        Column {
                            id: content
                            y: 30
                            width: parent.width

                            SideScroll {
                                id: body
                                visible: !block.picture
                                width: parent.width
                                height: codeText.height + 25.6
                                contentWidth: codeText.width + 28.8

                                TextEdit {
                                    id: codeText
                                    objectName: "codeText"
                                    Accessible.name: seg.language.length > 0 ? qsTr("%1 code").arg(seg.language) : qsTr("Code")
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

                                    TapHandler {
                                        acceptedButtons: Qt.RightButton
                                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                                        onTapped: root.openTextMenu(codeText, point.position)
                                    }
                                }
                            }

                            // The picture, or under the source why it is not one yet.
                            MermaidDiagram {
                                id: diagram
                                objectName: "markdownDiagram"
                                visible: block.mermaid && !(drawn && block.showSource)
                                active: block.mermaid
                                code: seg.code
                                width: parent.width
                                height: implicitHeight
                                textColor: root.mutedColor
                            }
                        }
                    }
                }

                Component {
                    id: table
                    Item {
                        id: grid
                        objectName: "markdownTable"

                        readonly property var spec: root.tableSpec(seg.payload)
                        readonly property var rows: [spec.header].concat(spec.rows)

                        // The table's lines, kept in step with its rows: one
                        // that grows as the reply streams is the only one
                        // whose cells are made again.
                        function syncLines() {
                            for (let r = 0; r < rows.length; ++r) {
                                const cells = JSON.stringify(rows[r]);
                                if (r >= lineModel.count)
                                    lineModel.append({
                                        cellsJson: cells
                                    });
                                else if (lineModel.get(r).cellsJson !== cells)
                                    lineModel.setProperty(r, "cellsJson", cells);
                            }
                            if (lineModel.count > rows.length)
                                lineModel.remove(rows.length, lineModel.count - rows.length);
                        }
                        onRowsChanged: syncLines()
                        ListModel {
                            id: lineModel
                        }
                        property bool expanded: Settings.setting("wordWrap") ?? true
                        property bool copied: false
                        property var widths: []
                        readonly property real naturalWidth: widths.reduce((sum, w) => sum + w, 0)
                        // Width 100%, at least max-content: spare room goes to
                        // the columns in proportion, as an auto table layout does.
                        readonly property real stretch: naturalWidth > 0 && naturalWidth < width ? width / naturalWidth : 1

                        function copy(format) {
                            root.copyText(format === "csv" ? spec.csv : spec.markdown);
                            copied = true;
                            copiedTimer.restart();
                        }

                        // Each column is as wide as its widest cell, capped at
                        // 24rem (a header only while collapsed), plus padding.
                        // A line's item, whose cell() is the delegate's own.
                        function lineAt(r: int): var {
                            return lines.itemAt(r);
                        }

                        function measure() {
                            const next = [];
                            for (let r = 0; r < lines.count; ++r) {
                                const line = lineAt(r);
                                // One that is going away answers nothing.
                                if (!line || typeof line.cell !== "function")
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
                                const line = lineAt(r);
                                for (let c = 0; line && typeof line.cell === "function" && c < line.cellCount; ++c) {
                                    if (line.cell(c))
                                        all.push(line.cell(c));
                                }
                            }
                            return all;
                        }

                        implicitWidth: naturalWidth
                        implicitHeight: footer.y + footer.height
                        onExpandedChanged: measureCells.restart()
                        // Made as tall as it stays: a table that grew a frame
                        // later would push the rows after it in a list down.
                        // Cells made later, as a list's spare rows are, are
                        // measured once they are there.
                        Component.onCompleted: {
                            syncLines();
                            measure();
                            tableBody.forceLayout();
                            measureCells.restart();
                        }

                        // Measures once the cells are laid out. A timer, not
                        // Qt.callLater: it dies with a table the stream turned
                        // into another kind, where a queued call would run on
                        // a destroyed context.
                        Timer {
                            id: measureCells
                            interval: 0
                            onTriggered: grid.measure()
                        }

                        Timer {
                            id: copiedTimer
                            interval: 1200
                            onTriggered: grid.copied = false
                        }

                        SideScroll {
                            id: tableScroll
                            width: grid.width
                            height: tableBody.height
                            contentWidth: grid.naturalWidth * grid.stretch

                            Column {
                                id: tableBody
                                Repeater {
                                    id: lines
                                    model: lineModel
                                    delegate: Item {
                                        id: line
                                        required property string cellsJson
                                        readonly property var modelData: JSON.parse(cellsJson)
                                        required property int index
                                        readonly property bool head: index === 0
                                        readonly property int cellCount: cells.count
                                        function boxAt(c: int): var {
                                            return cells.itemAt(c);
                                        }
                                        // A cell's text, null while it is being made.
                                        function cell(c: int): var {
                                            const box = boxAt(c);
                                            return box ? box.text : null;
                                        }
                                        width: tableScroll.contentWidth
                                        height: cellRow.rowHeight + 1
                                        Row {
                                            id: cellRow
                                            Repeater {
                                                id: cells
                                                // By count, so a row that grows keeps its cells
                                                // and only the one whose text changed is laid out.
                                                model: line.modelData.length
                                                delegate: Item {
                                                    id: cellBox
                                                    required property int index
                                                    readonly property string html: line.modelData[index] ?? ""
                                                    readonly property alias text: cellText
                                                    width: (grid.widths[index] ?? 0) * grid.stretch
                                                    height: cellRow.rowHeight
                                                    clip: true
                                                    RichText {
                                                        id: cellText
                                                        objectName: "tableCell"
                                                        x: 12
                                                        y: line.head ? 8.8 : 7.2
                                                        width: parent.width - 24
                                                        wrapMode: grid.expanded && !line.head ? TextEdit.WrapAtWordBoundaryOrAnywhere : TextEdit.NoWrap
                                                        font.pixelSize: Theme.type.meta.size
                                                        font.weight: line.head ? Font.DemiBold : Font.Normal
                                                        text: root.rich("<p align=\"" + (grid.spec.align[cellBox.index] ?? "left") + "\" style=\"margin:0;line-height:19.5px;-qt-line-height-type:minimum\">" + cellBox.html + "</p>")
                                                        onImplicitWidthChanged: measureCells.restart()
                                                    }
                                                }
                                            }
                                            readonly property real rowHeight: {
                                                let h = 0;
                                                for (let c = 0; c < cells.count; ++c) {
                                                    const text = line.cell(c);
                                                    if (text)
                                                        h = Math.max(h, grid.expanded && !line.head ? text.height : 19.5);
                                                }
                                                return h + (line.head ? 17.6 : 14.4);
                                            }
                                        }
                                        Rectangle {
                                            y: cellRow.rowHeight
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
                            note: [qsTr("Note"), "info", "#3b82f6", "#2563eb", "#60a5fa"],
                            tip: [qsTr("Tip"), "lightbulb", "#10b981", "#059669", "#34d399"],
                            important: [qsTr("Important"), "message-square-warning", "#a855f7", "#9333ea", "#c084fc"],
                            warning: [qsTr("Warning"), "triangle-alert", "#f59e0b", "#d97706", "#f59e0b"],
                            caution: [qsTr("Caution"), "octagon-alert", "#ef4444", "#dc2626", "#f87171"]
                        })
                        readonly property var kindOf: kinds[seg.alert] ?? null
                        readonly property color titleColor: kindOf ? (root.light ? kindOf[3] : kindOf[4]) : root.textColor

                        // The quote's own brick, once loaded.
                        readonly property Markdown quoted: inner.item as Markdown

                        implicitWidth: (quoted?.implicitWidth ?? 0) + inner.x
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
                            spacing: Theme.space.sm
                            ShellIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: quoteBox.kindOf ? quoteBox.kindOf[1] : ""
                                size: 14
                                color: quoteBox.titleColor
                            }
                            Text {
                                objectName: "alertTitle"
                                anchors.verticalCenter: parent.verticalCenter
                                text: quoteBox.kindOf ? quoteBox.kindOf[0] : ""
                                color: quoteBox.titleColor
                                font.family: root.uiFamily
                                font.pixelSize: Theme.type.prose.size
                                font.weight: Font.Medium
                            }
                        }

                        Loader {
                            id: inner
                            x: quoteBox.kindOf ? 12 : 12.8
                            y: quoteBox.kindOf ? alertTitle.height + 10.4 : 0
                            width: parent.width - x
                            height: quoteBox.quoted?.implicitHeight ?? 0
                            source: Qt.resolvedUrl("Markdown.qml")
                            onLoaded: {
                                const brick = inner.item as Markdown;
                                brick.fitWidth = Qt.binding(() => root.fitWidth);
                                // Before the text, which is parsed as it is set.
                                brick.lineBreaks = Qt.binding(() => root.lineBreaks);
                                brick.trusted = Qt.binding(() => root.trusted);
                                brick.selectable = Qt.binding(() => root.selectable);
                                brick.fontSize = Qt.binding(() => root.fontSize);
                                brick.fontWeight = Qt.binding(() => root.fontWeight);
                                brick.struck = Qt.binding(() => root.struck);
                                brick.text = Qt.binding(() => seg.payload);
                                // A quote reads muted; an alert's body is ordinary text.
                                brick.textColor = Qt.binding(() => quoteBox.kindOf ? root.textColor : root.mutedColor);
                                brick.runnable = Qt.binding(() => root.runnable && !root.streaming);
                                brick.linkPreviews = Qt.binding(() => root.linkPreviews);
                                brick.linkActivated.connect(root.linkActivated);
                                brick.runCommand.connect(root.runCommand);
                                brick.host = root;
                            }
                        }

                        function texts() {
                            return quoteBox.quoted ? quoteBox.quoted.texts() : [];
                        }

                        function linkAt(x: real, y: real): string {
                            return quoteBox.quoted ? quoteBox.quoted.linkAt(x - inner.x, y - inner.y) : "";
                        }
                    }
                }
            }
        }
    }
}
