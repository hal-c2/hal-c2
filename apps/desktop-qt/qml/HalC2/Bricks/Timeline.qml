pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell
import "js/changedFilesTree.js" as ChangedFilesTree

// A thread's timeline: the rows of a TimelineModel (Threads.timeline), or any
// model with its roles (rowId, kind, author, text, streaming, title, status,
// statusLabel, marker, entries, hiddenCount, expanded, files, time, icon,
// intent, attribution, meta, attachments, and optionally summary and summaryFailed).
//
//   Timeline { anchors.fill: parent; model: Threads.timeline }
//
// Rows sit in a centred column as wide as the composer and look like the web
// app's (apps/web/src/components/chat/MessagesTimeline.tsx, WorkLog.tsx). The
// view follows new output while it is at the end. Scrolling away stops that
// and offers a way back to the latest output. Folds and tool call groups open
// and close through the model's toggle(rowId). A message's time and actions
// show while the pointer is over it, or always without hover (alwaysShowMeta);
// hidden, they keep their place and still take clicks. An agent reply whose
// turn left a checkpoint offers Revert (revertRequested); files a reply
// changed or a tool call touched ask to be opened (fileActivated). What those
// do is the host's (ThreadView). A settled turn's group of calls reads as its
// summary and opens into the calls; a long message of the user's shows its
// first lines until it is asked for in full. A model that holds only a
// thread's newest turns (hasEarlier) is asked for the ones before them
// (loadEarlier()) when the user reaches the top, or while what is loaded does
// not fill the view; their rows go in above without moving what is on screen.
Item {
    id: root

    property var model: null
    // Whether the agent is working and what the indicator says; the model's
    // own when it has them.
    property bool working: root.model !== null && root.model.working === true
    // Whether the user's message is on its way to the MC: the indicator says
    // so until the agent starts working.
    property bool sending: false
    // Whether the view keeps the latest output in view.
    readonly property alias following: view.following
    // Whether the user has scrolled away from the latest output, as of their
    // last finished scroll: what a host makes room for while they read
    // (Composer's collapse on scroll). It never changes under the user's
    // hand, since room made mid-scroll would move the end the scroll is
    // measured against and hand the view back to following.
    readonly property alias scrolledAway: view.away
    // Whether the list says it is loading or its MC cannot be reached;
    // hosts that say so themselves turn it off.
    property bool showStatus: true
    // Whether a reply's row can revert the thread to its turn's checkpoint.
    property var revertable: rowId => root.model !== null && typeof root.model.checkpointOf === "function" && Object.keys(root.model.checkpointOf(rowId)).length > 0
    // Whether rows show their time and actions without the pointer over them:
    // touch screens have no hover (the web's pointer-coarse).
    property bool alwaysShowMeta: Qt.platform.os === "android" || Qt.platform.os === "ios"
    // The centred column rows are laid out in, as wide as the composer's.
    readonly property real columnWidth: Math.max(0, Math.min(width - 40, 768))

    signal linkActivated(string link)
    // A fold or tool call group was opened or closed.
    signal toggled(string rowId)
    // A file to open in the right panel: "diff" for a reply's changed files,
    // "files" for a file a tool call changed; `rowId` is the row it is on.
    signal fileActivated(string path, string tab, string rowId)
    // The user asked to revert the thread to this reply's turn.
    signal revertRequested(string rowId)
    // A message went to the clipboard.
    signal copied(string rowId)
    // A thread to open: a subagent's own, or the one a message came from
    // (the model's `thread` role, an id in this thread's environment).
    signal threadActivated(string threadId)
    // The user asked to edit from their message: the thread rewinds to before it.
    signal editRequested(string rowId)
    // Whether a user message's row can be edited from (rewindPointOf).
    property var editable: rowId => root.model !== null && typeof root.model.rewindPointOf === "function" && root.model.rewindPointOf(rowId).turn !== undefined
    // The pull request a message mentions is to be linked to the thread.
    signal pullRequestLinkRequested(string url)

    // Links the pull request a message mentions (the web's link action on a mention).
    component LinkPullRequestButton: IconButton {
        property string url
        objectName: "linkPullRequest"
        visible: url.length > 0
        icon: "git-pull-request"
        tip: qsTr("Link this pull request to the thread")
        onClicked: root.pullRequestLinkRequested(url)
    }

    // The user's long messages shown in full, by row id; kept here so a row
    // scrolled away and back stays as the user left it.
    property var fullMessages: ({})
    // packages/shared/src/chatMessages.ts shouldCollapseUserMessage.
    function collapsible(text) {
        return text.trim().length > 0 && (text.length > 600 || text.split("\n").length > 8);
    }
    function showFull(rowId, full) {
        const next = Object.assign({}, root.fullMessages);
        next[rowId] = full;
        root.fullMessages = next;
    }
    // Which folders of a reply's changed files are open, by row: `all`, and
    // the folders opened or closed one by one since. Closed until opened.
    // Folders are kept without a prototype so one named "constructor" or
    // "__proto__" is a folder like any other.
    property var changedFolders: ({})
    function foldersOf(rowId) {
        return root.changedFolders[rowId] ?? { all: false, folders: Object.create(null) };
    }
    function setFolders(rowId, all, folders) {
        const next = Object.assign({}, root.changedFolders);
        next[rowId] = { all: all, folders: folders };
        root.changedFolders = next;
    }
    function toggleFolder(rowId, path) {
        const open = root.foldersOf(rowId);
        const folders = Object.assign(Object.create(null), open.folders);
        folders[path] = !(folders[path] ?? open.all);
        root.setFolders(rowId, open.all, folders);
    }
    // The user cited a selection of a reply: an AssistantCitation's selector
    // {text, start, end, prefix, suffix}.
    signal cited(string messageId, var selector)

    // Whether a selection in a reply offers "Cite".
    property bool citable: false

    // Whether the model can put a message on the clipboard (copy(rowId)).
    readonly property bool canCopy: root.model !== null && typeof root.model.copy === "function"

    function copy(rowId) {
        root.model.copy(rowId);
        root.copied(rowId);
    }

    function toggle(rowId) {
        if (root.model && typeof root.model.toggle === "function")
            root.model.toggle(rowId);
        root.toggled(rowId);
    }

    function scrollToEnd() {
        view.following = true;
        view.stick();
    }

    // Whether the turns before the ones loaded are on their way.
    readonly property bool loadingEarlier: root.model !== null && root.model.loadingEarlier === true
    // Asks the model for the turns before the ones it holds, if it has any
    // and is not already fetching them.
    function loadEarlier() {
        if (root.model && root.model.hasEarlier === true && !root.loadingEarlier && typeof root.model.loadEarlier === "function")
            root.model.loadEarlier();
    }
    // What is loaded of a live thread leaves room in the view, so there is no
    // top to scroll to: the turns before it are fetched until it is filled.
    readonly property bool unfilled: root.model !== null && root.model.hasEarlier === true && !root.loadingEarlier && root.model.status === "live" && view.count > 0 && view.contentHeight + view.topMargin + view.bottomMargin < view.height
    onUnfilledChanged: if (unfilled)
        Qt.callLater(view.fill)

    // The model's list roles arrive as arrays from C++ and as ListModels from
    // a QML ListModel.
    function list(value) {
        if (value === undefined || value === null)
            return [];
        if (value.count !== undefined && typeof value.get === "function") {
            const items = [];
            for (let i = 0; i < value.count; ++i)
                items.push(value.get(i));
            return items;
        }
        return value;
    }

    // The long form of a row's or call's time, for its tooltip.
    function timeTitle(rowId, entryId) {
        return root.model && typeof root.model.timeTitle === "function" ? root.model.timeTitle(rowId, entryId) : "";
    }

    readonly property color textColor: Theme.palette.color("text", "#f5f5f5")
    readonly property color mutedColor: Theme.palette.color("textMuted", "#818181")
    readonly property color borderColor: Theme.palette.color("border", "#191919")
    readonly property color surfaceColor: Theme.palette.color("surface", "#111111")
    readonly property color accentColor: Theme.palette.color("accent", "#346bf1")
    readonly property color errorColor: Theme.palette.color("error", "#fb414a")
    readonly property color warningColor: Theme.palette.color("warning", "#fe9a00")
    readonly property string monoFamily: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
    readonly property string uiFamily: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
    // The web's tokens: bg-message, text-message-foreground, bg-accent (the
    // hover wash), bg-muted, bg-secondary, text-secondary-label,
    // text-icon-muted, text-tool-error-icon, success, info and the page.
    readonly property color messageColor: Theme.palette.color("messageSurface", "#141414")
    readonly property color messageTextColor: Theme.palette.color("messageForeground", "#f5f5f5")
    readonly property color hoverColor: Theme.palette.color("accentSurface", "#141414")
    readonly property color mutedSurfaceColor: Theme.palette.color("muted", "#111111")
    readonly property color secondaryColor: Theme.palette.color("secondary", "#111111")
    readonly property color secondaryTextColor: Theme.palette.color("secondaryForeground", "#f5f5f5")
    readonly property color labelColor: Theme.palette.color("secondaryLabel", "#818181")
    readonly property color iconColor: Theme.palette.color("iconMuted", "#818181")
    readonly property color toolErrorColor: Theme.palette.color("errorForeground", "#ff6467")
    readonly property color successColor: Theme.palette.color("success", "#00bc7d")
    readonly property color infoColor: Theme.palette.color("info", "#2b7fff")
    readonly property color canvasColor: Theme.palette.color("canvas", "#0a0a0a")

    component RowText: Text {
        color: root.textColor
        font.family: root.uiFamily
        font.pixelSize: Math.round(13 * Theme.fontScale)
        wrapMode: Text.Wrap
    }

    // A small text button under a message.
    component ActionLink: Text {
        id: action
        signal clicked
        color: actionHover.hovered ? root.textColor : root.mutedColor
        font.family: root.uiFamily
        font.pixelSize: Math.round(12 * Theme.fontScale)
        HoverHandler {
            id: actionHover
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            onTapped: action.clicked()
        }
    }

    // A row's time, its long form on hover (TimelineRowTimestamp).
    component Stamp: Text {
        id: stamp
        property string rowId
        property string entryId
        visible: text.length > 0
        color: root.mutedColor
        font.family: root.uiFamily
        font.pixelSize: Math.round(12 * Theme.fontScale)
        font.features: {
            "tnum": 1
        }
        HoverHandler {
            id: stampHover
        }
        ToolTip.visible: stampHover.hovered
        ToolTip.delay: 500
        // Asked for only while hovered.
        ToolTip.text: stampHover.hovered ? root.timeTitle(stamp.rowId, stamp.entryId) : ""
    }

    // A ghost icon button in a row's meta line (the web's xs ghost-muted).
    component IconButton: Rectangle {
        id: button
        property string icon
        property string tip
        property color tint: button.hovered ? root.textColor : root.mutedColor
        readonly property bool hovered: buttonHover.hovered
        signal clicked
        implicitWidth: 24
        implicitHeight: 24
        radius: 6
        color: button.hovered ? root.hoverColor : "transparent"
        Accessible.role: Accessible.Button
        Accessible.name: button.tip
        Accessible.onPressAction: button.clicked()
        ShellIcon {
            anchors.centerIn: parent
            name: button.icon
            size: 12
            color: button.tint
        }
        HoverHandler {
            id: buttonHover
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            onTapped: button.clicked()
        }
        ToolTip.visible: buttonHover.hovered && button.tip.length > 0
        ToolTip.delay: 500
        ToolTip.text: button.tip
    }

    // Copies a message, then shows a check for a second (MessageCopyButton).
    component CopyButton: IconButton {
        id: copyButton
        property string rowId
        property bool copied: false
        objectName: "copyMessage"
        visible: root.canCopy
        icon: copied ? "check" : "copy"
        tint: copied ? root.accentColor : hovered ? root.textColor : root.mutedColor
        tip: copied ? qsTr("Copied") : qsTr("Copy message")
        onClicked: {
            root.copy(copyButton.rowId);
            copyButton.copied = true;
            copiedTimer.restart();
        }
        Timer {
            id: copiedTimer
            interval: 1000
            onTriggered: copyButton.copied = false
        }
    }

    // A rounded status label (the web's status pills).
    component Pill: Rectangle {
        property alias text: pillText.text
        property alias textColor: pillText.color
        property alias mono: pillText.font.family
        implicitWidth: pillText.implicitWidth + 12
        implicitHeight: pillText.implicitHeight + 4
        radius: height / 2
        color: "transparent"
        Text {
            id: pillText
            anchors.centerIn: parent
            font.family: root.uiFamily
            font.pixelSize: Math.round(10 * Theme.fontScale)
        }
    }

    // One line of the work log (WorkLog.tsx): a 24px icon box, the label
    // truncated, then the trailing children. Interactive lines wash on hover.
    component WorkLine: Rectangle {
        id: line
        property string iconName
        property color iconTint: root.iconColor
        property string label
        property color labelColor: root.labelColor
        property int labelWeight: Font.Normal
        property bool interactive: false
        default property alias trailing: trailingRow.data
        readonly property bool hovered: lineHover.hovered
        signal clicked(point position)
        implicitHeight: 28
        radius: 6
        color: line.interactive && line.hovered ? Qt.alpha(root.hoverColor, 0.2) : "transparent"
        ShellIcon {
            x: 6
            anchors.verticalCenter: parent.verticalCenter
            visible: line.iconName.length > 0
            name: line.iconName
            size: 16
            strokeWidth: 1.8
            color: line.iconTint
        }
        Text {
            x: 32
            width: Math.max(0, trailingRow.x - x - 6)
            anchors.verticalCenter: parent.verticalCenter
            text: line.label
            textFormat: Text.PlainText
            color: line.labelColor
            font.family: root.uiFamily
            font.pixelSize: Math.round(14 * Theme.fontScale)
            font.weight: line.labelWeight
            elide: Text.ElideRight
            maximumLineCount: 1
        }
        Row {
            id: trailingRow
            anchors.right: parent.right
            anchors.rightMargin: 2
            height: parent.height
            spacing: 6
        }
        HoverHandler {
            id: lineHover
            cursorShape: line.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
        }
        TapHandler {
            enabled: line.interactive
            onTapped: eventPoint => line.clicked(eventPoint.position)
        }
    }

    ListView {
        id: view
        objectName: "timelineRows"

        property bool following: true
        property bool positioning: false
        property bool away: false

        function settleAway() {
            if (!moving && !dragging && !scrollBar.pressed)
                away = !following;
        }
        onFollowingChanged: settleAway()

        // Another thread's rows open at their latest output, however far
        // the last thread was scrolled.
        function restart() {
            heldIndex = -1;
            settlingIndex = -1;
            following = true;
            away = false;
            Qt.callLater(stick);
        }

        // Moves to the end without counting as the user scrolling.
        function stick() {
            // Never pull the view from under the user's hand.
            if (moving || dragging || scrollBar.pressed)
                return;
            positioning = true;
            positionViewAtEnd();
            positioning = false;
        }
        function nearEnd() {
            return contentY + height >= originY + contentHeight - 4;
        }
        // Once the rows are laid out and still leave room.
        function fill() {
            forceLayout();
            if (root.unfilled)
                root.loadEarlier();
        }

        // Rows that go in above the first (earlier turns) leave what is on
        // screen where it is. A ListView resting at its very top would show
        // them instead, so the first row in view is held to its place.
        property int heldIndex: -1
        property real heldOffset: 0
        function hold() {
            heldIndex = following ? -1 : indexAt(width / 2, contentY + topMargin + 1);
            const item = heldIndex >= 0 ? itemAtIndex(heldIndex) : null;
            if (item)
                heldOffset = item.y - contentY;
            else
                heldIndex = -1;
        }
        function release(added) {
            if (heldIndex < 0)
                return;
            const index = heldIndex + added;
            heldIndex = -1;
            positioning = true;
            forceLayout();
            positionViewAtIndex(index, ListView.Beginning);
            const item = itemAtIndex(index);
            if (item)
                contentY = item.y - heldOffset;
            positioning = false;
            // The rows just made above it are still finding their heights.
            settlingIndex = index;
            settlingOffset = heldOffset;
        }
        // The row that was held stays where it is while the rows above it
        // settle, until the user moves the view or the rows change again.
        property int settlingIndex: -1
        property real settlingOffset: 0
        function settle() {
            if (settlingIndex < 0 || following || moving || dragging || scrollBar.pressed)
                return;
            const item = itemAtIndex(settlingIndex);
            if (!item || Math.abs(item.y - settlingOffset - contentY) < 0.5)
                return;
            positioning = true;
            contentY = item.y - settlingOffset;
            positioning = false;
        }
        onMovementStarted: settlingIndex = -1
        Connections {
            target: root.model
            ignoreUnknownSignals: true
            function onRowsAboutToBeInserted(parent, first, last) {
                if (first === 0)
                    view.hold();
            }
            function onRowsInserted(parent, first, last) {
                // Once every listener of the model has heard of them.
                if (first === 0 && view.heldIndex >= 0)
                    Qt.callLater(view.release, last - first + 1);
            }
        }

        anchors.fill: parent
        anchors.bottomMargin: indicator.visible ? indicator.height : 0
        clip: true
        topMargin: 12
        bottomMargin: 12
        boundsBehavior: Flickable.StopAtBounds
        model: root.model
        onModelChanged: restart()
        ScrollBar.vertical: ScrollBar {
            id: scrollBar
            onPressedChanged: view.settleAway()
        }

        // Only the user's own scrolling (wheel, drag, keys, scroll bar)
        // decides whether the view follows; the list settling its layout or
        // growing below the end does not.
        onContentYChanged: {
            if (!positioning && (moving || dragging || scrollBar.pressed)) {
                following = nearEnd();
                if (atYBeginning)
                    root.loadEarlier();
            }
        }
        onMovementEnded: {
            following = nearEnd();
            settleAway();
            if (atYBeginning)
                root.loadEarlier();
        }
        onContentHeightChanged: {
            if (following)
                Qt.callLater(stick);
            else
                settle();
        }
        onCountChanged: {
            // Another row list: what was held is no longer at that index.
            settlingIndex = -1;
            if (following)
                Qt.callLater(stick);
        }
        onHeightChanged: if (following)
            Qt.callLater(stick)

        delegate: Item {
            id: row

            required property int index
            required property string rowId
            required property string kind
            required property var author
            required property var text
            required property var streaming
            required property var title
            required property var status
            required property var statusLabel
            required property var marker
            required property var entries
            required property var hiddenCount
            required property var expanded
            required property var files
            required property var time
            required property var icon
            required property var intent
            required property var attribution
            required property var meta
            // Roles a model may leave out (summary, summaryFailed).
            required property var model
            required property var messageId
            required property var attachments
            // The tool calls whose details are open, by id.
            property var openCalls: ({})
            // Whether the row's time and actions show: only this row's
            // pointer changes it.
            readonly property bool showMeta: root.alwaysShowMeta || rowHover.hovered
            // The space under the row, by kind (the web's row padding).
            readonly property int gap: {
                switch (row.kind) {
                case "message":
                    // Commentary sits closer to the work that follows it.
                    return row.author !== "user" && row.meta !== true ? 8 : 16;
                case "plan":
                    return 16;
                case "fold":
                    return 6;
                case "subagent":
                    return 4;
                default:
                    return 8;
                }
            }

            HoverHandler {
                id: rowHover
            }

            width: ListView.view.width
            height: body.item ? (body.item as Item).implicitHeight + row.gap : 0

            Loader {
                id: body
                x: Math.round((row.width - root.columnWidth) / 2)
                width: root.columnWidth
                sourceComponent: {
                    switch (row.kind) {
                    case "message":
                        return row.author === "user" ? userMessage : assistantMessage;
                    case "work":
                        return work;
                    case "fold":
                        return fold;
                    case "plan":
                        return plan;
                    case "subagent":
                        return subagent;
                    case "error":
                        return error;
                    default:
                        return marker;
                    }
                }
            }

            Component {
                id: userMessage
                Column {
                    spacing: 4
                    // Who sent it, when not the user; a known thread opens.
                    RowText {
                        id: attribution
                        readonly property string thread: row.model.thread ?? ""
                        objectName: "messageAttribution"
                        visible: text.length > 0
                        anchors.right: parent.right
                        anchors.rightMargin: 4
                        text: row.attribution ?? ""
                        color: attribution.thread.length > 0 && attributionHover.hovered ? root.textColor : Qt.alpha(root.mutedColor, 0.7)
                        font.pixelSize: Math.round(11 * Theme.fontScale)
                        HoverHandler {
                            id: attributionHover
                            enabled: attribution.thread.length > 0
                            cursorShape: Qt.PointingHandCursor
                        }
                        TapHandler {
                            enabled: attribution.thread.length > 0
                            onTapped: root.threadActivated(attribution.thread)
                        }
                    }
                    // How it reached the agent (UserMessageIntentMarker).
                    Row {
                        visible: (row.intent ?? "").length > 0 && row.intent !== "turn_start"
                        anchors.right: parent.right
                        anchors.rightMargin: 4
                        spacing: 4
                        ShellIcon {
                            visible: row.intent !== "queued_turn"
                            anchors.verticalCenter: parent.verticalCenter
                            name: "redo-2"
                            size: 12
                            color: root.mutedColor
                        }
                        RowText {
                            text: row.intent === "queued_turn" ? qsTr("Queued") : qsTr("Steer")
                            color: root.mutedColor
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            wrapMode: Text.NoWrap
                            HoverHandler {
                                id: intentHover
                            }
                            ToolTip.visible: intentHover.hovered && (row.marker ?? "").length > 0
                            ToolTip.delay: 500
                            ToolTip.text: row.marker ?? ""
                        }
                    }
                    // The images sent with it, loaded from the MC once
                    // the model has their addresses.
                    Flow {
                        id: images
                        visible: root.list(row.attachments).length > 0
                        anchors.right: parent.right
                        width: Math.round(parent.width * 0.8)
                        layoutDirection: Qt.RightToLeft
                        spacing: 8
                        Repeater {
                            model: root.list(row.attachments)
                            delegate: Rectangle {
                                id: attachment

                                required property var modelData
                                readonly property bool pictured: picture.status === Image.Ready

                                objectName: "attachment-" + modelData.id
                                Accessible.role: Accessible.Graphic
                                Accessible.name: modelData.name ?? ""
                                // As wide as the picture is at this height; a square until it loads.
                                width: pictured ? Math.min(images.width, Math.round(height * picture.implicitWidth / picture.implicitHeight)) : height
                                height: 200
                                radius: 2
                                color: root.messageColor
                                border.color: root.borderColor

                                Component.onCompleted: if (root.model !== null && typeof root.model.loadAttachment === "function")
                                    root.model.loadAttachment(modelData.id)

                                Image {
                                    id: picture
                                    anchors.fill: parent
                                    anchors.margins: 1
                                    source: attachment.modelData.url ?? ""
                                    // Decoded at twice the height shown, for dense screens.
                                    sourceSize.height: 400
                                    fillMode: Image.PreserveAspectFit
                                }
                                Column {
                                    visible: !attachment.pictured
                                    anchors.centerIn: parent
                                    width: parent.width - 16
                                    spacing: 6
                                    ShellIcon {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        name: "image"
                                        size: 20
                                        color: root.iconColor
                                    }
                                    RowText {
                                        width: parent.width
                                        horizontalAlignment: Text.AlignHCenter
                                        text: attachment.modelData.name ?? ""
                                        color: root.mutedColor
                                        font.pixelSize: Math.round(12 * Theme.fontScale)
                                        wrapMode: Text.NoWrap
                                        elide: Text.ElideMiddle
                                    }
                                }
                            }
                        }
                    }
                    Rectangle {
                        id: bubble
                        readonly property bool collapsible: root.collapsible(row.text ?? "")
                        readonly property bool collapsed: collapsible && root.fullMessages[row.rowId] !== true
                        objectName: "userMessageBody"
                        // A message of images alone has no bubble.
                        visible: (row.text ?? "").length > 0
                        anchors.right: parent.right
                        width: Math.min(parent.width * 0.8, userText.implicitWidth + 24)
                        // The web's max-h-44.
                        height: (collapsed ? Math.min(176, userText.implicitHeight) : userText.implicitHeight) + 24
                        radius: 16
                        color: root.messageColor
                        clip: collapsed
                        Markdown {
                            id: userText
                            x: 12
                            y: 12
                            width: Math.min(implicitWidth, body.width * 0.8 - 24)
                            text: row.text ?? ""
                            lineBreaks: true
                            fitWidth: true
                            textColor: root.messageTextColor
                            onLinkActivated: link => root.linkActivated(link)
                        }
                    }
                    ActionLink {
                        objectName: "messageExpand"
                        visible: bubble.collapsible
                        anchors.right: parent.right
                        anchors.rightMargin: 4
                        text: bubble.collapsed ? qsTr("Show full message") : qsTr("Show less")
                        Accessible.role: Accessible.Button
                        Accessible.name: text
                        onClicked: root.showFull(row.rowId, bubble.collapsed)
                    }
                    // A message that did not reach the agent says why.
                    Pill {
                        visible: text.length > 0 && text !== "completed" && text !== "pending" && text !== "waiting"
                        anchors.right: parent.right
                        anchors.rightMargin: 4
                        text: row.status ?? ""
                        textColor: root.errorColor
                        color: Qt.alpha(root.errorColor, 0.08)
                        border.color: Qt.alpha(root.errorColor, 0.25)
                    }
                    Row {
                        anchors.right: parent.right
                        anchors.rightMargin: 4
                        height: 24
                        spacing: 8
                        opacity: row.showMeta ? 1 : 0
                        Behavior on opacity {
                            NumberAnimation {
                                duration: 200
                            }
                        }
                        Stamp {
                            anchors.verticalCenter: parent.verticalCenter
                            rowId: row.rowId
                            text: row.time ?? ""
                        }
                        LinkPullRequestButton {
                            url: row.model.pullRequestUrl ?? ""
                        }
                        IconButton {
                            objectName: "editFromHere"
                            icon: "pencil"
                            tip: qsTr("Edit from here")
                            // Asked when the pointer comes over the message.
                            visible: row.showMeta && root.editable(row.rowId)
                            onClicked: root.editRequested(row.rowId)
                        }
                        CopyButton {
                            rowId: row.rowId
                        }
                    }
                }
            }

            Component {
                id: assistantMessage
                Column {
                    leftPadding: 4
                    rightPadding: 4
                    topPadding: 2
                    bottomPadding: 2
                    Markdown {
                        // Over the row's files and actions, for "Cite".
                        z: 1
                        width: parent.width - 8
                        text: row.text ?? ""
                        streaming: row.streaming ?? false
                        citable: root.citable && row.streaming !== true && !!row.messageId
                        onLinkActivated: link => root.linkActivated(link)
                        onCited: selector => root.cited(row.messageId, selector)
                        // "Cite" under a short reply's last line reaches over the next row.
                        onSelectionChanged: row.z = selection !== null ? 1 : 0
                    }
                    // The files the reply's turn changed (ChangedFilesCard).
                    Item {
                        id: changedFiles
                        readonly property var changed: root.list(row.files)
                        readonly property var open: root.foldersOf(row.rowId)
                        readonly property bool nested: ChangedFilesTree.hasFolders(changed)
                        visible: changed.length > 0
                        width: parent.width - 8
                        height: filesCard.y + filesCard.height
                        Rectangle {
                            id: filesCard
                            y: 16
                            width: parent.width
                            height: filesColumn.implicitHeight
                            radius: 8
                            color: root.secondaryColor
                            Column {
                                id: filesColumn
                                width: parent.width
                                Item {
                                    width: parent.width
                                    height: 32
                                    Row {
                                        x: 12
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 12
                                        RowText {
                                            text: changedFiles.changed.length === 1 ? qsTr("1 changed file") : qsTr("%1 changed files").arg(changedFiles.changed.length)
                                            font.pixelSize: Math.round(12 * Theme.fontScale)
                                            font.weight: Font.Medium
                                            wrapMode: Text.NoWrap
                                        }
                                        Row {
                                            readonly property var totals: changedFiles.changed.reduce((sum, file) => [sum[0] + (file.additions ?? 0), sum[1] + (file.deletions ?? 0)], [0, 0])
                                            spacing: 4
                                            RowText {
                                                text: "+" + parent.totals[0]
                                                color: root.successColor
                                                font.family: root.monoFamily
                                                font.pixelSize: Math.round(12 * Theme.fontScale)
                                            }
                                            RowText {
                                                text: "-" + parent.totals[1]
                                                color: root.errorColor
                                                font.family: root.monoFamily
                                                font.pixelSize: Math.round(12 * Theme.fontScale)
                                            }
                                        }
                                    }
                                    IconButton {
                                        objectName: "changedFoldersToggle"
                                        visible: changedFiles.nested
                                        anchors.right: openDiff.left
                                        anchors.rightMargin: 4
                                        anchors.verticalCenter: parent.verticalCenter
                                        icon: changedFiles.open.all ? "chevrons-down-up" : "chevrons-up-down"
                                        tip: changedFiles.open.all ? qsTr("Collapse all folders") : qsTr("Expand all folders")
                                        onClicked: root.setFolders(row.rowId, !changedFiles.open.all, Object.create(null))
                                    }
                                    // The turn's whole diff.
                                    Rectangle {
                                        id: openDiff
                                        objectName: "openTurnDiff"
                                        anchors.right: parent.right
                                        anchors.rightMargin: 8
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: openDiffRow.implicitWidth + 14
                                        height: 24
                                        radius: 6
                                        color: openDiffHover.hovered ? root.hoverColor : "transparent"
                                        Accessible.role: Accessible.Button
                                        Accessible.name: qsTr("Open diff")
                                        Row {
                                            id: openDiffRow
                                            anchors.centerIn: parent
                                            spacing: 6
                                            ShellIcon {
                                                anchors.verticalCenter: parent.verticalCenter
                                                name: "file-diff"
                                                size: 12
                                                color: openDiffHover.hovered ? root.textColor : root.mutedColor
                                            }
                                            RowText {
                                                // The web drops the words below 24rem.
                                                visible: filesCard.width >= 384
                                                text: qsTr("Open diff")
                                                color: openDiffHover.hovered ? root.textColor : root.mutedColor
                                                font.pixelSize: Math.round(12 * Theme.fontScale)
                                                wrapMode: Text.NoWrap
                                            }
                                        }
                                        HoverHandler {
                                            id: openDiffHover
                                            cursorShape: Qt.PointingHandCursor
                                        }
                                        TapHandler {
                                            onTapped: root.fileActivated("", "diff", row.rowId)
                                        }
                                        ToolTip.visible: openDiffHover.hovered
                                        ToolTip.delay: 500
                                        ToolTip.text: qsTr("Open the full diff")
                                    }
                                }
                                Column {
                                    x: 8
                                    width: parent.width - 16
                                    bottomPadding: 8
                                    Repeater {
                                        model: ChangedFilesTree.rows(changedFiles.changed, changedFiles.open.all, changedFiles.open.folders)
                                        delegate: Rectangle {
                                            id: changedFile
                                            required property var modelData
                                            readonly property bool folder: modelData.kind === "directory"
                                            objectName: folder ? "changedFolder" : "changedFile"
                                            width: parent.width
                                            height: 28
                                            radius: 6
                                            color: changedFileHover.hovered ? Qt.alpha(root.hoverColor, 0.6) : "transparent"
                                            Accessible.role: Accessible.Button
                                            Accessible.name: modelData.path
                                            Accessible.onPressAction: changedFile.activate()
                                            function activate() {
                                                if (changedFile.folder)
                                                    root.toggleFolder(row.rowId, changedFile.modelData.path);
                                                else
                                                    root.fileActivated(changedFile.modelData.path, "diff", row.rowId);
                                            }
                                            ShellIcon {
                                                id: folderChevron
                                                visible: changedFile.folder
                                                x: 8 + changedFile.modelData.depth * 14
                                                anchors.verticalCenter: parent.verticalCenter
                                                name: "chevron-right"
                                                size: 14
                                                rotation: changedFile.modelData.expanded ? 90 : 0
                                                color: Qt.alpha(root.mutedColor, 0.7)
                                            }
                                            ShellIcon {
                                                id: fileIcon
                                                // A file sits under its folder's name, past the chevron.
                                                x: folderChevron.x + (changedFiles.nested ? 22 : 0)
                                                anchors.verticalCenter: parent.verticalCenter
                                                name: !changedFile.folder ? "file" : changedFile.modelData.expanded ? "folder" : "folder-closed"
                                                size: 14
                                                color: Qt.alpha(root.mutedColor, 0.7)
                                            }
                                            RowText {
                                                x: fileIcon.x + 22
                                                width: Math.max(0, fileStat.x - x - 8)
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: changedFile.modelData.name
                                                color: changedFile.folder ? (changedFileHover.hovered ? Qt.alpha(root.textColor, 0.9) : Qt.alpha(root.mutedColor, 0.9)) : changedFileHover.hovered ? root.textColor : Qt.alpha(root.textColor, 0.85)
                                                font.family: root.monoFamily
                                                font.pixelSize: Math.round((changedFile.folder ? 11 : 12) * Theme.fontScale)
                                                wrapMode: Text.NoWrap
                                                elide: Text.ElideMiddle
                                            }
                                            Row {
                                                id: fileStat
                                                anchors.right: parent.right
                                                anchors.rightMargin: 8
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: 4
                                                RowText {
                                                    text: "+" + changedFile.modelData.additions
                                                    color: root.successColor
                                                    font.family: root.monoFamily
                                                    font.pixelSize: Math.round(10 * Theme.fontScale)
                                                }
                                                RowText {
                                                    text: "-" + changedFile.modelData.deletions
                                                    color: root.errorColor
                                                    font.family: root.monoFamily
                                                    font.pixelSize: Math.round(10 * Theme.fontScale)
                                                }
                                            }
                                            HoverHandler {
                                                id: changedFileHover
                                                cursorShape: Qt.PointingHandCursor
                                            }
                                            TapHandler {
                                                onTapped: changedFile.activate()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // Its actions and time, on its settled turn's last reply.
                    Row {
                        visible: row.meta === true && row.streaming !== true
                        topPadding: 6
                        height: 30
                        spacing: 8
                        opacity: row.showMeta ? 1 : 0
                        Behavior on opacity {
                            NumberAnimation {
                                duration: 200
                            }
                        }
                        IconButton {
                            objectName: "forkFromResponse"
                            icon: "git-fork"
                            tip: qsTr("Fork from this response")
                            visible: row.showMeta && root.model !== null && typeof root.model.finishedRunOf === "function" && root.model.finishedRunOf(row.rowId).length > 0
                            onClicked: Shell.dispatch("thread.forkFromRun", {
                                runId: root.model.finishedRunOf(row.rowId)
                            })
                        }
                        IconButton {
                            objectName: "revertToTurn"
                            icon: "undo-2"
                            tip: qsTr("Revert to here")
                            // Asked again when the pointer comes over the reply
                            // or its turn's files land.
                            visible: {
                                row.files;
                                return row.showMeta && root.revertable(row.rowId);
                            }
                            onClicked: root.revertRequested(row.rowId)
                        }
                        Pill {
                            visible: text.length > 0 && text !== "completed"
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.status ?? ""
                            textColor: root.mutedColor
                            mono: root.monoFamily
                            border.color: Qt.alpha(root.borderColor, 0.7)
                        }
                        LinkPullRequestButton {
                            url: row.model.pullRequestUrl ?? ""
                        }
                        CopyButton {
                            rowId: row.rowId
                        }
                        Stamp {
                            anchors.verticalCenter: parent.verticalCenter
                            rowId: row.rowId
                            text: row.time ?? ""
                        }
                    }
                }
            }

            Component {
                id: work
                Column {
                    id: workGroup
                    readonly property string summary: row.model.summary ?? ""

                    // The calls on screen, kept in step with the row's
                    // entries by id: a call that streams changes its own
                    // line, and the lines beside it are left alone.
                    function callOf(entry) {
                        return {
                            id: entry.id ?? "",
                            type: entry.type ?? "",
                            status: entry.status ?? "",
                            statusLabel: entry.statusLabel ?? "",
                            icon: entry.icon ?? "",
                            time: entry.time ?? "",
                            label: entry.label ?? "",
                            detail: entry.detail ?? "",
                            command: entry.command ?? "",
                            path: entry.path ?? "",
                            exited: entry.exitCode !== undefined && entry.exitCode !== null,
                            exitCode: entry.exitCode ?? 0
                        };
                    }
                    function syncCalls() {
                        const next = root.list(row.entries);
                        let at = 0;
                        for (; at < next.length && at < calls.count; ++at) {
                            const want = callOf(next[at]);
                            const have = calls.get(at);
                            if (have.id !== want.id)
                                break;
                            for (const key in want) {
                                if (have[key] !== want[key])
                                    calls.setProperty(at, key, want[key]);
                            }
                        }
                        // From the first line that is another call's.
                        if (at < calls.count)
                            calls.remove(at, calls.count - at);
                        for (; at < next.length; ++at)
                            calls.append(callOf(next[at]));
                    }
                    ListModel {
                        id: calls
                    }
                    Connections {
                        target: row
                        function onEntriesChanged() {
                            workGroup.syncCalls();
                        }
                    }
                    // A QML ListModel keeps its entries in a list of their
                    // own, which changes in place.
                    Connections {
                        target: row.entries && typeof row.entries.get === "function" ? row.entries : null
                        ignoreUnknownSignals: true
                        function onDataChanged() {
                            workGroup.syncCalls();
                        }
                        function onCountChanged() {
                            workGroup.syncCalls();
                        }
                    }
                    Component.onCompleted: syncCalls()
                    // What a settled group did, or "+N previous tool calls"
                    // while its turn runs (WorkGroupToggleTimelineRow).
                    WorkLine {
                        objectName: "workGroupToggle"
                        visible: (row.hiddenCount ?? 0) > 0
                        width: parent.width
                        iconName: "hammer"
                        iconTint: row.model.summaryFailed === true ? Qt.alpha(root.toolErrorColor, 0.4) : root.iconColor
                        label: workGroup.summary.length > 0 ? workGroup.summary : row.expanded ? qsTr("Show fewer tool calls") : qsTr("+%1 previous tool calls").arg(row.hiddenCount)
                        interactive: true
                        onClicked: root.toggle(row.rowId)
                        Item {
                            visible: workGroup.summary.length > 0
                            anchors.verticalCenter: parent.verticalCenter
                            width: 16
                            height: 16
                            ShellIcon {
                                anchors.centerIn: parent
                                name: "chevron-right"
                                size: 12
                                color: Qt.alpha(root.iconColor, 0.7)
                                rotation: row.expanded ? 90 : 0
                            }
                        }
                    }
                    Repeater {
                        model: calls
                        delegate: Column {
                            id: call
                            // The call's fields, each of which changes on its own.
                            required property var model
                            readonly property var modelData: model
                            // Kept on the row, so streamed output does not close it.
                            readonly property bool open: row.openCalls[modelData.id] === true
                            readonly property bool hasDetails: (modelData.detail ?? "").length > 0 || (modelData.command ?? "").length > 0
                            readonly property bool failed: modelData.status === "failed" || modelData.statusLabel === qsTr("Failed")
                            // Reasoning opens into text, the rest into a panel
                            // (WorkLogDetails).
                            readonly property bool panel: modelData.type !== "reasoning"
                            width: parent.width
                            WorkLine {
                                id: callLine
                                objectName: "workCall"
                                width: parent.width
                                iconName: call.modelData.icon || "hammer"
                                iconTint: call.failed ? Qt.alpha(root.toolErrorColor, 0.4) : root.iconColor
                                label: call.modelData.label ?? ""
                                interactive: call.hasDetails
                                onClicked: position => {
                                    // Open takes its own tap.
                                    if (openLink.visible && openLink.contains(openLink.mapFromItem(callLine, position)))
                                        return;
                                    const next = Object.assign({}, row.openCalls);
                                    next[call.modelData.id] = !call.open;
                                    row.openCalls = next;
                                }
                                ActionLink {
                                    id: openLink
                                    objectName: "openFile"
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: (call.modelData.path ?? "").length > 0
                                    text: qsTr("Open")
                                    onClicked: root.fileActivated(call.modelData.path, "files", row.rowId)
                                }
                                RowText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: text.length > 0
                                    text: call.modelData.statusLabel ?? ""
                                    wrapMode: Text.NoWrap
                                    font.pixelSize: Math.round(12 * Theme.fontScale)
                                    color: call.failed ? root.toolErrorColor : root.mutedColor
                                }
                                Stamp {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: text.length > 0 && (callLine.hovered || root.alwaysShowMeta)
                                    rowId: row.rowId
                                    entryId: call.modelData.id ?? ""
                                    text: call.modelData.time ?? ""
                                }
                                Item {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 16
                                    height: 16
                                    ShellIcon {
                                        anchors.centerIn: parent
                                        visible: call.hasDetails
                                        name: "chevron-right"
                                        size: 12
                                        color: Qt.alpha(root.iconColor, 0.7)
                                        rotation: call.open ? 90 : 0
                                    }
                                }
                            }
                            Item {
                                visible: call.open
                                x: 28
                                width: parent.width - 28
                                height: detailsBox.y + detailsBox.height
                                Rectangle {
                                    id: detailsBox
                                    y: call.panel ? 4 : 0
                                    width: parent.width
                                    height: details.implicitHeight + details.y * 2
                                    radius: 6
                                    color: call.panel ? Qt.alpha(root.mutedSurfaceColor, 0.4) : "transparent"
                                    Column {
                                        id: details
                                        x: call.panel ? 12 : 2
                                        y: call.panel ? 8 : 4
                                        width: parent.width - x * 2
                                        spacing: call.panel ? 4 : 12
                                        RowText {
                                            visible: text.length > 0
                                            width: parent.width
                                            text: call.modelData.command ? "$ " + call.modelData.command : ""
                                            textFormat: Text.PlainText
                                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                            font.family: root.monoFamily
                                            font.pixelSize: Math.round(11 * Theme.fontScale)
                                        }
                                        RowText {
                                            visible: text.length > 0
                                            width: parent.width
                                            // Laid out once it shows: text streamed
                                            // into a closed call costs nothing.
                                            text: call.open ? call.modelData.detail ?? "" : ""
                                            textFormat: Text.PlainText
                                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                            font.family: call.panel ? root.monoFamily : root.uiFamily
                                            font.pixelSize: call.panel ? 11 : 14
                                            lineHeight: 1.15
                                            color: call.panel ? root.labelColor : root.textColor
                                            maximumLineCount: 40
                                            elide: Text.ElideRight
                                        }
                                        RowText {
                                            visible: call.modelData.exited
                                            text: qsTr("Exit code %1").arg(call.modelData.exitCode)
                                            font.pixelSize: Math.round(11 * Theme.fontScale)
                                            color: root.mutedColor
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Component {
                id: fold
                // "Worked for 32s", then its chevron (TurnFoldTimelineRow).
                Item {
                    implicitHeight: 36
                    Row {
                        id: foldButton
                        y: 4
                        height: 23
                        leftPadding: 4
                        rightPadding: 4
                        spacing: 4
                        RowText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.title ?? ""
                            color: foldHover.hovered ? root.textColor : root.mutedColor
                            font.pixelSize: Math.round(14 * Theme.fontScale)
                            wrapMode: Text.NoWrap
                        }
                        ShellIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: row.expanded ? "chevron-down" : "chevron-right"
                            size: 14
                            color: foldHover.hovered ? root.textColor : root.mutedColor
                        }
                        HoverHandler {
                            id: foldHover
                            cursorShape: Qt.PointingHandCursor
                        }
                        TapHandler {
                            onTapped: root.toggle(row.rowId)
                        }
                    }
                    Stamp {
                        anchors.right: parent.right
                        anchors.rightMargin: 6
                        anchors.verticalCenter: foldButton.verticalCenter
                        visible: text.length > 0 && row.showMeta
                        rowId: row.rowId
                        text: row.time ?? ""
                    }
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: 1
                        color: Qt.alpha(root.borderColor, 0.6)
                    }
                }
            }

            Component {
                id: plan
                Rectangle {
                    // The card's padding (p-4, sm:p-5).
                    readonly property int pad: root.width >= 640 ? 20 : 16
                    implicitHeight: planBody.implicitHeight + pad * 2 + 4
                    color: "transparent"
                    // ProposedPlanCard, inset by its px-1 py-0.5 wrapper.
                    Rectangle {
                        x: 4
                        y: 2
                        width: parent.width - 8
                        height: parent.height - 4
                        radius: 24
                        color: Qt.alpha(root.surfaceColor, 0.7)
                        border.color: Qt.alpha(root.borderColor, 0.8)
                    }
                    Column {
                        id: planBody
                        x: 4 + parent.pad
                        y: 2 + parent.pad
                        width: parent.width - x * 2
                        spacing: 16
                        Row {
                            width: parent.width
                            spacing: 8
                            Rectangle {
                                id: planBadge
                                anchors.verticalCenter: parent.verticalCenter
                                width: planBadgeText.implicitWidth + 12
                                height: 22
                                radius: 6
                                color: root.secondaryColor
                                RowText {
                                    id: planBadgeText
                                    anchors.centerIn: parent
                                    text: qsTr("Plan")
                                    color: root.secondaryTextColor
                                    font.pixelSize: Math.round(12 * Theme.fontScale)
                                    font.weight: Font.Medium
                                    wrapMode: Text.NoWrap
                                }
                            }
                            RowText {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - planBadge.width - 8
                                text: row.title ?? ""
                                font.pixelSize: Math.round(14 * Theme.fontScale)
                                font.weight: Font.Medium
                                wrapMode: Text.NoWrap
                                elide: Text.ElideRight
                            }
                        }
                        Markdown {
                            width: parent.width
                            text: row.text ?? ""
                            onLinkActivated: link => root.linkActivated(link)
                        }
                    }
                }
            }

            Component {
                id: subagent
                // A subagent's avatar, title and progress (SubagentTimelineLink).
                Item {
                    id: subagentRow
                    readonly property color dot: {
                        switch (row.status) {
                        case "pending":
                        case "running":
                        case "waiting":
                            return root.infoColor;
                        case "completed":
                            return root.successColor;
                        case "failed":
                            return root.errorColor;
                        case "idle":
                            return Qt.alpha(root.mutedColor, 0.5);
                        default:
                            return Qt.alpha(root.mutedColor, 0.6);
                        }
                    }
                    readonly property bool failed: row.status === "failed"
                    readonly property bool hasDetail: (row.text ?? "").length > 0
                    // Its own thread, when it has one, and the model it runs on.
                    readonly property string thread: row.model.thread ?? ""
                    readonly property string agentModel: row.model.agentModel ?? ""
                    objectName: "subagentRow"
                    implicitHeight: Math.max(24, subagentText.implicitHeight) + 12
                    HoverHandler {
                        enabled: subagentRow.thread.length > 0
                        cursorShape: Qt.PointingHandCursor
                    }
                    TapHandler {
                        enabled: subagentRow.thread.length > 0
                        onTapped: root.threadActivated(subagentRow.thread)
                    }
                    Rectangle {
                        id: avatar
                        x: 8
                        anchors.verticalCenter: parent.verticalCenter
                        width: 24
                        height: 24
                        radius: 12
                        color: root.mutedSurfaceColor
                        border.color: Qt.alpha(root.borderColor, 0.7)
                        ShellIcon {
                            anchors.centerIn: parent
                            name: row.icon || "bot"
                            size: 14
                            color: root.mutedColor
                        }
                        // The status dot, ringed in the page's colour.
                        Rectangle {
                            x: 15
                            y: 15
                            width: 12
                            height: 12
                            radius: 6
                            color: subagentRow.dot
                            border.width: 2
                            border.color: root.canvasColor
                        }
                    }
                    Column {
                        id: subagentText
                        x: avatar.x + 34
                        width: parent.width - x - 8
                        anchors.verticalCenter: parent.verticalCenter
                        Row {
                            width: parent.width
                            spacing: 8
                            RowText {
                                id: subagentTitle
                                width: Math.min(implicitWidth, parent.width - (subagentStatus.visible ? subagentStatus.width + 8 : 0))
                                text: row.title ?? ""
                                font.pixelSize: Math.round(12 * Theme.fontScale)
                                font.weight: Font.Medium
                                wrapMode: Text.NoWrap
                                elide: Text.ElideRight
                            }
                            RowText {
                                id: subagentStatus
                                anchors.baseline: subagentTitle.baseline
                                visible: subagentRow.hasDetail && row.status !== "completed" && text.length > 0
                                text: row.statusLabel ?? ""
                                color: subagentRow.failed ? root.errorColor : root.mutedColor
                                font.pixelSize: Math.round(10 * Theme.fontScale)
                                wrapMode: Text.NoWrap
                            }
                        }
                        RowText {
                            width: parent.width
                            objectName: "subagentDetail"
                            text: (subagentRow.agentModel.length > 0 ? subagentRow.agentModel + " · " : "") + (subagentRow.hasDetail ? row.text : (row.statusLabel ?? ""))
                            color: subagentRow.failed ? root.errorColor : root.mutedColor
                            font.pixelSize: Math.round(11 * Theme.fontScale)
                            wrapMode: Text.NoWrap
                            elide: Text.ElideRight
                        }
                    }
                }
            }

            Component {
                id: error
                // The failure's heading, then its message (the web's failed
                // work entry).
                Column {
                    WorkLine {
                        id: errorLine
                        width: parent.width
                        iconName: row.icon || "circle-alert"
                        iconTint: root.errorColor
                        label: row.title ?? ""
                        labelColor: root.errorColor
                        labelWeight: Font.Medium
                        Stamp {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: text.length > 0 && row.showMeta
                            rowId: row.rowId
                            text: row.time ?? ""
                        }
                    }
                    RowText {
                        visible: text.length > 0
                        x: 28
                        width: parent.width - 28
                        topPadding: 4
                        bottomPadding: 4
                        text: row.text ?? ""
                        textFormat: Text.PlainText
                        color: Qt.alpha(root.textColor, 0.8)
                        font.pixelSize: Math.round(14 * Theme.fontScale)
                    }
                }
            }

            Component {
                id: marker
                // A line across the column with the marker in its middle
                // (TimelineSystemDivider).
                Item {
                    implicitHeight: markerContent.height + 24
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(0, markerContent.x - 8)
                        height: 1
                        color: Qt.alpha(root.borderColor, 0.7)
                    }
                    Row {
                        id: markerContent
                        anchors.centerIn: parent
                        height: 16
                        spacing: 6
                        ShellIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: name.length > 0
                            name: row.icon ?? ""
                            size: 12
                            color: root.mutedColor
                        }
                        RowText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.title ?? ""
                            color: root.mutedColor
                            font.pixelSize: Math.round(11 * Theme.fontScale)
                            font.weight: Font.Medium
                            wrapMode: Text.NoWrap
                        }
                        RowText {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: (row.text ?? "").length > 0
                            width: Math.min(implicitWidth, 320, Math.max(0, root.columnWidth - 160))
                            text: "· " + (row.text ?? "")
                            color: root.mutedColor
                            opacity: 0.7
                            font.pixelSize: Math.round(11 * Theme.fontScale)
                            wrapMode: Text.NoWrap
                            elide: Text.ElideRight
                        }
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: parent.right
                        width: Math.max(0, parent.width - markerContent.x - markerContent.width - 8)
                        height: 1
                        color: Qt.alpha(root.borderColor, 0.7)
                    }
                }
            }
        }

        header: RowText {
            width: ListView.view ? ListView.view.width : 0
            visible: root.showStatus && root.model !== null && (root.model.status === "unreachable" || (root.model.status === "loading" && view.count === 0))
            height: visible ? implicitHeight + 12 : 0
            horizontalAlignment: Text.AlignHCenter
            color: root.model && root.model.status === "unreachable" ? root.warningColor : root.mutedColor
            text: {
                if (!root.model)
                    return "";
                if (root.model.status === "unreachable")
                    return qsTr("This thread's MC cannot be reached: %1").arg(root.model.problem ?? "");
                return qsTr("Loading…");
            }
        }
    }

    // "Working for 12s" under the rows (the web's working row), a static
    // line redrawn once a second while the agent works; "Sending…" while the
    // user's message is on its way.
    Item {
        id: indicator
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 42
        visible: root.working || root.sending
        property int tick: 0
        Timer {
            interval: 1000
            repeat: true
            running: root.working && root.visible
            onTriggered: indicator.tick++
        }
        Item {
            x: Math.round((indicator.width - root.columnWidth) / 2)
            width: root.columnWidth
            height: 36
            RowText {
                objectName: "workingLabel"
                x: 4
                y: 4
                height: 24
                verticalAlignment: Text.AlignVCenter
                color: root.mutedColor
                font.pixelSize: Math.round(14 * Theme.fontScale)
                font.features: {
                    "tnum": 1
                }
                wrapMode: Text.NoWrap
                text: {
                    indicator.tick;
                    if (!root.working)
                        return qsTr("Sending…");
                    return root.model && typeof root.model.workingLabel === "function" ? root.model.workingLabel() : qsTr("Working");
                }
            }
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: Qt.alpha(root.borderColor, 0.6)
            }
        }
    }

    // Earlier turns are on their way: a static line over the top of the
    // rows, so nothing under it moves when it comes and goes.
    Rectangle {
        objectName: "loadingEarlier"
        visible: root.loadingEarlier
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: view.top
        anchors.topMargin: 12
        width: earlierText.implicitWidth + 16
        height: 24
        radius: 12
        color: root.canvasColor
        border.color: Qt.alpha(root.borderColor, 0.6)
        RowText {
            id: earlierText
            anchors.centerIn: parent
            text: qsTr("Loading earlier turns…")
            color: root.mutedColor
            font.pixelSize: Math.round(12 * Theme.fontScale)
            wrapMode: Text.NoWrap
        }
    }

    // Scrolling down where the list goes no further, as when the room made
    // for reading shows the end, returns to it. Only at the end: a wheel that
    // reaches here mid-thread (over an overlay) is not one the list refused.
    WheelHandler {
        target: null
        onWheel: event => {
            if (!view.following && view.nearEnd() && (event.angleDelta.y < 0 || event.pixelDelta.y < 0))
                root.scrollToEnd();
        }
    }

    // Back to the latest output once the user scrolled away (the web's glass
    // "Scroll to end" button).
    Rectangle {
        id: jump
        objectName: "jumpToLatest"
        visible: !view.following && view.count > 0
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: view.bottom
        anchors.bottomMargin: 12
        width: jumpRow.implicitWidth + 16
        height: 24
        radius: 12
        color: jumpHover.hovered ? root.hoverColor : root.canvasColor
        border.color: Qt.alpha(root.borderColor, 0.6)
        Row {
            id: jumpRow
            anchors.centerIn: parent
            spacing: 4
            ShellIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "chevron-down"
                size: 14
                color: root.textColor
            }
            RowText {
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Scroll to end")
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.NoWrap
            }
        }
        HoverHandler {
            id: jumpHover
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            onTapped: root.scrollToEnd()
        }
    }
}
