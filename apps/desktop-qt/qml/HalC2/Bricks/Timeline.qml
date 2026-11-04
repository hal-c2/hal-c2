pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell
import "js/changedFilesTree.js" as ChangedFilesTree

// A thread's timeline: the rows of a TimelineModel (Threads.timeline), or any
// model with its roles (rowId, kind, author, text, streaming, title, status,
// statusLabel, marker, entries, hiddenCount, expanded, files, time, icon,
// intent, attribution, meta, attachments, and optionally summary, summaryFailed
// and sentFiles).
//
//   Timeline { anchors.fill: parent; model: Threads.timeline }
//
// Rows sit in a centred column as wide as the composer. The
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

    ImageViewer {
        id: largeImage
        model: root.model
    }

    // A changed file's own actions (FileActionsController).
    FileEntryMenu {
        id: changedFileMenu
    }
    // Whether the environment can find the thread's files on its machine:
    // only then does a changed file offer its actions.
    readonly property bool locatable: (Shell.state.workspace?.worktreePath ?? Shell.state.workspace?.projectRoot ?? "").length > 0

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
    // touch screens have no hover.
    property bool alwaysShowMeta: Qt.platform.os === "android" || Qt.platform.os === "ios"
    // The centred column rows are laid out in, as wide as the composer's.
    readonly property real columnWidth: Math.max(0, Math.min(width - 40, 768))

    // The hover cards and clicks of pull request links (Markdown.linkPreviews).
    property var linkPreviews: null

    signal linkActivated(string link, bool external)
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

    // Links the pull request a message mentions.
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
    // Whether a user message is long enough to show only its first lines.
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
    // Where the user left each long group of calls, by row:
    // {entryId, offset} of the call at its top (scrollAnchor).
    property var groupAnchors: ({})
    // How tall an open group grows before it scrolls (max-h min(18rem, 50dvh)).
    readonly property real openGroupHeight: Math.min(288, height / 2)
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
    // Whether a reply's complete shell command offers "Run in terminal",
    // which asks the host to run it (runCommand).
    property bool runnable: false
    signal runCommand(string command)

    // Whether a long press on a tool call or a failure copies what it says:
    // the phone's activity log (TimelineModel::phone).
    readonly property bool holdToCopy: root.model !== null && root.model.phone === true

    // Whether the model can put a message on the clipboard (copy(rowId)).
    readonly property bool canCopy: root.model !== null && typeof root.model.copy === "function"

    // Copies a message: empty when it is on the clipboard, else why not.
    function copy(rowId) {
        const failure = root.model.copy(rowId) ?? "";
        if (failure.length === 0)
            root.copied(rowId);
        return failure;
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

    // A page up (-1) or down (1), less a few lines of the page before so the
    // eye keeps its place. Going up stops the view following; reaching the end
    // follows again, as the user's own scrolling does.
    function page(direction) {
        const top = view.originY - view.topMargin;
        const bottom = view.originY + view.contentHeight + view.bottomMargin - view.height;
        const target = Math.max(top, Math.min(Math.max(top, bottom), view.contentY + direction * Math.max(0, view.height - 48)));
        view.settlingIndex = -1;
        view.positioning = true;
        view.contentY = target;
        view.positioning = false;
        if (direction > 0 && view.nearEnd()) {
            root.scrollToEnd();
            return;
        }
        view.following = view.nearEnd();
        if (target <= top)
            root.loadEarlier();
    }

    // The very start of what is loaded (`top`), or the end.
    function toEdge(top) {
        if (!top) {
            root.scrollToEnd();
            return;
        }
        view.settlingIndex = -1;
        view.positioning = true;
        // The start is where the list guessed until its first rows are made;
        // once they are, it is where they are.
        view.contentY = view.originY - view.topMargin;
        view.forceLayout();
        view.contentY = view.originY - view.topMargin;
        view.positioning = false;
        view.following = view.nearEnd();
        root.loadEarlier();
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

    // Where a work line's label starts, past its icon; what opens under a
    // line starts there too.
    readonly property int workInset: 2 * Theme.space.sm + Theme.icon.md
    readonly property color textColor: Theme.palette.color("ink", "#f2f3f5")
    readonly property color mutedColor: Theme.palette.color("inkTertiary", "#8b919e")
    readonly property color borderColor: Theme.palette.color("border", "#191919")
    readonly property color surfaceColor: Theme.palette.color("surface", "#111111")
    readonly property color accentColor: Theme.palette.color("accent", "#346bf1")
    readonly property color errorColor: Theme.palette.color("errorForeground", "#fb414a")
    readonly property color warningColor: Theme.palette.color("warningForeground", "#fe9a00")
    readonly property string monoFamily: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
    readonly property string uiFamily: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
    // The row colours: the message surface and its text, the hover wash, the
    // muted and secondary surfaces, labels and icons, the tool error icon,
    // success, info and the page.
    readonly property color messageColor: Theme.palette.color("messageSurface", "#141414")
    readonly property color messageTextColor: Theme.palette.color("messageForeground", "#f5f5f5")
    readonly property color hoverColor: Theme.palette.color("surfaceRaised", "#1c1f24")
    readonly property color mutedSurfaceColor: Theme.palette.color("muted", "#111111")
    readonly property color secondaryColor: Theme.palette.color("secondary", "#111111")
    readonly property color secondaryTextColor: Theme.palette.color("secondaryForeground", "#f5f5f5")
    readonly property color labelColor: Theme.palette.color("inkSecondary", "#b8bdc7")
    readonly property color iconColor: Theme.palette.color("inkTertiary", "#8b919e")
    readonly property color toolErrorColor: Theme.palette.color("errorForeground", "#ff6467")
    readonly property color successColor: Theme.palette.color("success", "#00bc7d")
    readonly property color infoColor: Theme.palette.color("info", "#2b7fff")
    readonly property color canvasColor: Theme.palette.color("canvas", "#0a0a0a")

    component RowText: Text {
        color: root.textColor
        font.family: root.uiFamily
        font.pixelSize: Theme.type.body.size
        wrapMode: Text.Wrap
    }

    // A small text button under a message.
    component ActionLink: Text {
        id: action
        signal clicked
        Accessible.role: Accessible.Button
        Accessible.name: action.text
        Accessible.onPressAction: action.clicked()
        color: actionHover.hovered ? root.textColor : root.mutedColor
        font.family: root.uiFamily
        font.pixelSize: Theme.type.meta.size
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
        font.pixelSize: Theme.type.meta.size
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

    // A ghost icon button in a row's meta line.
    component IconButton: Rectangle {
        id: button
        property string icon
        property string tip
        property color tint: button.hovered ? root.textColor : root.mutedColor
        readonly property bool hovered: buttonHover.hovered
        signal clicked
        implicitWidth: Theme.control.sm
        implicitHeight: Theme.control.sm
        radius: Theme.radiusSm
        color: button.hovered ? root.hoverColor : "transparent"
        Accessible.role: Accessible.Button
        Accessible.name: button.tip
        Accessible.onPressAction: button.clicked()
        ShellIcon {
            anchors.centerIn: parent
            name: button.icon
            size: Theme.icon.sm
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

    // Copies a message, then says beside itself for a second that it did
    // ("Copied!", and a check) or why it could not (MessageCopyButton,
    // anchoredCopyToast).
    component CopyButton: IconButton {
        id: copyButton
        property string rowId
        property bool copied: false
        // Why the last copy failed, while it is shown.
        property string failure: ""
        objectName: "copyMessage"
        visible: root.canCopy
        icon: copied ? "check" : "copy"
        tint: copied ? root.accentColor : hovered ? root.textColor : root.mutedColor
        tip: notice.visible ? "" : qsTr("Copy message")
        onClicked: {
            copyButton.failure = root.copy(copyButton.rowId);
            copyButton.copied = copyButton.failure.length === 0;
            copiedTimer.restart();
        }
        Timer {
            id: copiedTimer
            interval: 1000
            onTriggered: {
                copyButton.copied = false;
                copyButton.failure = "";
            }
        }
        Rectangle {
            id: notice
            objectName: "copyNotice"
            readonly property string title: copyButton.copied ? qsTr("Copied!") : qsTr("Failed to copy")
            visible: copyButton.copied || copyButton.failure.length > 0
            z: 2
            x: Math.round((copyButton.width - width) / 2)
            y: -height - Theme.space.xs
            width: Math.min(noticeColumn.implicitWidth, 280) + 2 * Theme.space.sm
            height: noticeColumn.implicitHeight + 2 * Theme.space.xs
            radius: Theme.radiusSm
            color: Theme.palette.color("surfaceOverlay", "#1c1f24")
            border.color: Theme.palette.color("borderStrong", "#2c3039")
            border.width: 1
            Column {
                id: noticeColumn
                x: Theme.space.sm
                y: Theme.space.xs
                width: parent.width - 2 * Theme.space.sm
                RowText {
                    objectName: "copyNoticeTitle"
                    text: notice.title
                    color: root.textColor
                    font.pixelSize: Theme.type.meta.size
                    wrapMode: Text.NoWrap
                }
                RowText {
                    objectName: "copyNoticeReason"
                    visible: copyButton.failure.length > 0
                    width: Math.min(implicitWidth, 280)
                    text: copyButton.failure
                    color: root.mutedColor
                    font.pixelSize: Theme.type.meta.size
                    wrapMode: Text.Wrap
                }
            }
        }
    }

    // A rounded status label.
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
            font.pixelSize: Theme.type.caption.size
        }
    }

    // One line of the work log: a 24px icon box, the label
    // truncated, then the trailing children. Interactive lines wash on hover.
    component WorkLine: Rectangle {
        id: line
        property string iconName
        // A website's, an integration's or an app's own icon, in place of
        // `iconName` once it has loaded; the kind's stays where it fails.
        property string iconSource
        property color iconTint: root.iconColor
        property string label
        property color labelColor: root.labelColor
        property int labelWeight: Font.Normal
        property bool interactive: false
        // What an answered question was answered with, after the label.
        property string preview
        default property alias trailing: trailingRow.data
        readonly property bool hovered: lineHover.hovered
        // A changed file's path keeps its end, the file name.
        property int labelElide: Text.ElideRight
        // What a long press copies where lines copy so (holdToCopy).
        property string copyText
        property bool copied: false
        signal clicked(point position)
        Accessible.role: line.interactive ? Accessible.Button : Accessible.StaticText
        Accessible.name: line.preview.length > 0 ? line.label + ": " + line.preview : line.label
        Accessible.onPressAction: if (line.interactive)
            line.clicked(Qt.point(0, 0))
        implicitHeight: Theme.control.md
        radius: Theme.radiusSm
        color: line.interactive && line.hovered ? root.hoverColor : "transparent"
        ShellIcon {
            objectName: "workLineIcon"
            x: Theme.space.sm
            anchors.verticalCenter: parent.verticalCenter
            visible: line.iconName.length > 0 && ownIcon.status !== Image.Ready
            name: line.iconName
            size: Theme.icon.md
            color: line.iconTint
        }
        Image {
            id: ownIcon
            objectName: "workLineOwnIcon"
            x: Theme.space.sm
            width: Theme.icon.md
            height: Theme.icon.md
            anchors.verticalCenter: parent.verticalCenter
            visible: status === Image.Ready
            source: line.iconSource
            sourceSize: Qt.size(32, 32)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            opacity: 0.7
        }
        Text {
            id: lineLabel
            readonly property real room: Math.max(0, trailingRow.x - x - Theme.space.sm)
            x: root.workInset
            width: line.preview.length > 0 ? Math.min(implicitWidth, room) : room
            anchors.verticalCenter: parent.verticalCenter
            text: line.label
            textFormat: Text.PlainText
            color: line.labelColor
            font.family: root.uiFamily
            font.pixelSize: Theme.type.body.size
            font.weight: line.labelWeight
            elide: line.labelElide
            maximumLineCount: 1
        }
        Text {
            objectName: "workCallPreview"
            visible: line.preview.length > 0
            x: lineLabel.x + lineLabel.width + Theme.space.sm
            width: Math.max(0, trailingRow.x - x - Theme.space.sm)
            anchors.verticalCenter: parent.verticalCenter
            text: line.preview
            textFormat: Text.PlainText
            color: root.textColor
            font.family: root.uiFamily
            font.pixelSize: Theme.type.body.size
            elide: Text.ElideRight
            maximumLineCount: 1
        }
        Row {
            id: trailingRow
            anchors.right: parent.right
            anchors.rightMargin: Theme.space.xxs
            height: parent.height
            spacing: Theme.space.sm
            RowText {
                objectName: "workLineCopied"
                visible: line.copied
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Copied")
                wrapMode: Text.NoWrap
                font.pixelSize: Theme.type.meta.size
                color: root.accentColor
            }
        }
        HoverHandler {
            id: lineHover
            cursorShape: line.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
        }
        TapHandler {
            enabled: line.interactive
            onTapped: eventPoint => line.clicked(eventPoint.position)
        }
        TapHandler {
            enabled: root.holdToCopy && line.copyText.length > 0
            onLongPressed: {
                Shell.setClipboardText(line.copyText);
                line.copied = true;
                copiedTimer.restart();
            }
        }
        Timer {
            id: copiedTimer
            interval: 1500
            onTriggered: line.copied = false
        }
    }

    ListView {
        id: view
        objectName: "timelineRows"

        property bool following: true
        property bool positioning: false
        property bool away: false
        // The height each row was last laid out at, by row id. Heights from
        // another column width or text size are forgotten: a row made again
        // at one would snap to its own a moment later.
        property var heights: ({})
        readonly property string laidOutAt: [root.columnWidth, Theme.fontScale, Theme.fontUi, Theme.fontMono, Theme.fontSizeCode].join()
        onLaidOutAtChanged: heights = {}

        function settleAway() {
            if (!moving && !dragging && !scrollBar.pressed)
                away = !following;
        }
        onFollowingChanged: settleAway()

        // Another thread's rows open at their latest output, however far
        // the last thread was scrolled.
        function restart() {
            heights = {};
            heldIndex = -1;
            settlingIndex = -1;
            following = true;
            away = false;
            Qt.callLater(stick);
        }

        // Moves to the end without counting as the user scrolling.
        function stick() {
            // Never pull the view from under the user's hand; a queued stick
            // outlived by the user leaving the end does nothing.
            if (!following || moving || dragging || scrollBar.pressed)
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
        onMovementStarted: {
            settlingIndex = -1;
            movedFrom = contentY;
        }
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
            // Turns let go of far above (keepFrom()) leave the same way.
            function onRowsAboutToBeRemoved(parent, first, last) {
                if (first === 0)
                    view.hold();
            }
            function onRowsRemoved(parent, first, last) {
                if (first === 0 && view.heldIndex >= 0)
                    Qt.callLater(view.release, -(last - first + 1));
            }
        }

        // The model holds what is read from here on and a margin above it,
        // and lets go of the rest; scrolling back up fetches it again.
        function keepRead() {
            if (moving || dragging || scrollBar.pressed || root.loadingEarlier || !root.model || typeof root.model.keepFrom !== "function")
                return;
            const index = indexAt(width / 2, contentY + topMargin + 1);
            if (index >= 0)
                root.model.keepFrom(index);
        }

        anchors.fill: parent
        anchors.bottomMargin: indicator.visible ? indicator.height : 0
        clip: true
        // A click in the conversation puts the keyboard on it: Page Up and
        // Page Down page through it, Home and End go to its ends.
        activeFocusOnTab: true
        Accessible.role: Accessible.List
        Accessible.name: qsTr("Conversation")
        Keys.onPressed: event => {
            if (event.modifiers & (Qt.AltModifier | Qt.MetaModifier | Qt.ShiftModifier))
                return;
            const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
            if (event.key === Qt.Key_PageUp && !ctrl)
                root.page(-1);
            else if (event.key === Qt.Key_PageDown && !ctrl)
                root.page(1);
            else if (event.key === Qt.Key_Home)
                root.toEdge(true);
            else if (event.key === Qt.Key_End)
                root.toEdge(false);
            else
                return;
            event.accepted = true;
        }
        // Set when a click put the keyboard here, so only Tab draws the ring.
        property bool tapped: false
        onActiveFocusChanged: if (!activeFocus)
            tapped = false
        TapHandler {
            onTapped: {
                view.tapped = true;
                view.forceActiveFocus();
            }
        }
        topMargin: 12
        bottomMargin: 12
        boundsBehavior: Flickable.StopAtBounds
        model: root.model
        onModelChanged: restart()
        // Sections by kind tell a row whether a system divider is next to it
        // (ListView.nextSection, previousSection); no section is drawn.
        section.property: "kind"
        ScrollBar.vertical: ScrollBar {
            id: scrollBar
            Accessible.name: qsTr("Scroll conversation")
            onPressedChanged: view.settleAway()
        }

        // Only the user's own scrolling (wheel, drag, keys, scroll bar)
        // decides whether the view follows; the list settling its layout or
        // growing below the end does not. Leaving the end stops it following,
        // and only going down to the end follows again: a scroll up the list
        // did not take (rows measured above can cut a wheel's short), ending
        // where a host's room for reading shows the end, leaves the user away.
        property real movedFrom: 0
        property real lastY: 0
        function userScrolled(from) {
            following = nearEnd() && (following || contentY > from);
        }
        onContentYChanged: {
            if (!positioning && (moving || dragging || scrollBar.pressed)) {
                userScrolled(lastY);
                if (atYBeginning)
                    root.loadEarlier();
            }
            lastY = contentY;
        }
        onMovementEnded: {
            userScrolled(movedFrom);
            settleAway();
            if (atYBeginning)
                root.loadEarlier();
            else
                keepRead();
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
            if (following) {
                Qt.callLater(stick);
                Qt.callLater(keepRead);
            }
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
            // A system divider follows, or went before: it keeps 24 above
            // it and 16 below, whatever the rows around it reserve.
            readonly property bool beforeMarker: ListView.nextSection === "marker"
            readonly property bool afterMarker: ListView.previousSection === "marker"
            // The space under the row, by kind. Space a body keeps clear
            // at its foot (`tail`, for its time and actions) counts toward
            // a divider's.
            readonly property int gap: {
                if (row.kind === "marker")
                    return Theme.space.lg;
                if (row.beforeMarker)
                    return Math.max(0, Theme.space.xl - (body.item ? body.item.tail ?? 0 : 0));
                switch (row.kind) {
                case "message":
                    // Commentary sits closer to the work that follows it.
                    return row.author !== "user" && row.meta !== true ? Theme.space.sm : Theme.space.lg;
                case "plan":
                    return Theme.space.lg;
                case "fold":
                    return Theme.space.sm;
                case "subagent":
                    return Theme.space.xs;
                default:
                    return Theme.space.sm;
                }
            }

            HoverHandler {
                id: rowHover
            }

            width: ListView.view.width
            height: madeHeight > 0 ? madeHeight : laidHeight
            readonly property real laidHeight: body.item ? (body.item as Item).implicitHeight + row.gap : 0
            // A row the list makes again (scrolled back to, or laid out
            // afresh) starts at the height it last had. One that settled its
            // height a frame later would push the rows after it down every
            // time it was made, and a followed end with them.
            property real madeHeight: view.heights[rowId] ?? 0
            function remember() {
                madeHeight = 0;
                if (laidHeight > 0)
                    view.heights[rowId] = laidHeight;
            }
            onLaidHeightChanged: if (madeHeight === 0 || laidHeight === madeHeight)
                remember()
            Component.onCompleted: if (madeHeight === 0 || laidHeight === madeHeight)
                remember()
            // What it settles at instead, as when the window was resized
            // since, it takes once it has had the time to.
            Timer {
                running: row.madeHeight > 0
                interval: 250
                onTriggered: row.remember()
            }

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
                    case "thinking":
                        return thinking;
                    default:
                        // A finished worker's notification names its thread: a card.
                        return (row.model.thread ?? "").length > 0 ? workerResult : marker;
                    }
                }
            }

            Component {
                id: userMessage
                // A block on inset across the column, left-aligned like the
                // reply under it; what was sent with it and its actions sit
                // on the same left edge.
                Item {
                    id: userRoot
                    // Its time and actions keep a line under the block only
                    // where they always show, and are read there; on hover
                    // they float on its edge. Nothing at its foot is blank.
                    readonly property real tail: 0
                    implicitHeight: userColumn.implicitHeight
                    Column {
                        id: userColumn
                        width: parent.width
                        spacing: Theme.space.xs
                        // A hairline between turns: over each message that
                        // starts one (not a steer into the running turn), unless
                        // a system divider already sits over it.
                        Item {
                            objectName: "turnDivider"
                            visible: row.index > 0 && !row.afterMarker && ((row.intent ?? "").length === 0 || row.intent === "turn_start" || row.intent === "queued_turn")
                            width: parent.width
                            height: Theme.space.lg
                            Rectangle {
                                width: parent.width
                                height: 1
                                color: root.borderColor
                            }
                        }
                        // Who sent it, when not the user; a known thread opens.
                        RowText {
                            id: attribution
                            readonly property string thread: row.model.thread ?? ""
                            objectName: "messageAttribution"
                            Accessible.role: attribution.thread.length > 0 ? Accessible.Link : Accessible.StaticText
                            Accessible.name: attribution.text
                            Accessible.onPressAction: if (attribution.thread.length > 0)
                                root.threadActivated(attribution.thread)
                            visible: text.length > 0
                            text: row.attribution ?? ""
                            color: attribution.thread.length > 0 && attributionHover.hovered ? root.textColor : root.mutedColor
                            font.pixelSize: Theme.type.caption.size
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
                            spacing: Theme.space.xs
                            ShellIcon {
                                visible: row.intent !== "queued_turn"
                                anchors.verticalCenter: parent.verticalCenter
                                name: "redo-2"
                                size: Theme.icon.sm
                                color: root.mutedColor
                            }
                            RowText {
                                text: row.intent === "queued_turn" ? qsTr("Queued") : qsTr("Steer")
                                color: root.mutedColor
                                font.pixelSize: Theme.type.meta.size
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
                            width: parent.width
                            spacing: Theme.space.sm
                            Repeater {
                                model: root.list(row.attachments)
                                delegate: Rectangle {
                                    id: attachment

                                    required property var modelData
                                    required property int index
                                    readonly property bool pictured: picture.status === Image.Ready

                                    function openLarge() {
                                        forceActiveFocus();
                                        largeImage.showImages(root.list(row.attachments), index, attachment);
                                    }

                                    objectName: "attachment-" + modelData.id
                                    Accessible.role: Accessible.Graphic
                                    Accessible.name: modelData.name ?? ""
                                    // As wide as the picture is at this height; a square until it loads.
                                    width: pictured ? Math.min(images.width, Math.round(height * picture.implicitWidth / picture.implicitHeight)) : height
                                    height: 200
                                    radius: Theme.radiusXs
                                    color: root.messageColor
                                    border.color: activeFocus ? root.iconColor : root.borderColor
                                    activeFocusOnTab: true
                                    Keys.onReturnPressed: openLarge()
                                    Keys.onEnterPressed: openLarge()
                                    Keys.onSpacePressed: openLarge()

                                    MouseArea {
                                        objectName: "attachmentOpenLarge-" + attachment.modelData.id
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: attachment.openLarge()
                                    }

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
                                        width: parent.width - 2 * Theme.space.sm
                                        spacing: Theme.space.sm
                                        ShellIcon {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            name: "image"
                                            size: Theme.icon.lg
                                            color: root.iconColor
                                        }
                                        RowText {
                                            width: parent.width
                                            horizontalAlignment: Text.AlignHCenter
                                            text: attachment.modelData.name ?? ""
                                            color: root.mutedColor
                                            font.pixelSize: Theme.type.meta.size
                                            wrapMode: Text.NoWrap
                                            elide: Text.ElideMiddle
                                        }
                                    }
                                }
                            }
                        }
                        // The other files sent with it, by name, kind and size.
                        Flow {
                            id: sentFiles
                            readonly property var files: root.list(row.model.sentFiles)
                            visible: files.length > 0
                            width: parent.width
                            spacing: Theme.space.sm
                            Repeater {
                                model: sentFiles.files
                                delegate: Rectangle {
                                    id: sentFile

                                    required property var modelData

                                    objectName: "sentFile-" + modelData.id
                                    Accessible.role: Accessible.StaticText
                                    Accessible.name: (modelData.detail ?? "").length > 0 ? qsTr("%1, %2").arg(modelData.name).arg(modelData.detail) : (modelData.name ?? "")
                                    width: Math.min(sentFiles.width, fileRow.implicitWidth + 2 * Theme.space.md)
                                    height: Theme.control.lg
                                    radius: Theme.radiusMd
                                    color: root.messageColor
                                    border.color: activeFocus ? root.iconColor : root.borderColor
                                    activeFocusOnTab: true
                                    function openViewer() {
                                        Shell.dispatch("attachment.sent.view", { id: modelData.id, name: modelData.name, mimeType: modelData.mimeType ?? "" });
                                    }
                                    Keys.onReturnPressed: openViewer()
                                    Keys.onEnterPressed: openViewer()
                                    Keys.onSpacePressed: openViewer()

                                    MouseArea {
                                        objectName: "sentFileOpen-" + sentFile.modelData.id
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: sentFile.openViewer()
                                    }

                                    Row {
                                        id: fileRow
                                        x: Theme.space.md
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.space.sm
                                        ShellIcon {
                                            anchors.verticalCenter: parent.verticalCenter
                                            name: "file"
                                            size: Theme.icon.sm
                                            color: root.iconColor
                                        }
                                        RowText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            // The name gives way so the kind and size stay whole.
                                            width: Math.max(0, Math.min(implicitWidth, sentFiles.width - 2 * Theme.space.md - Theme.icon.sm - fileRow.spacing - (fileDetail.visible ? fileDetail.implicitWidth + fileRow.spacing : 0)))
                                            text: sentFile.modelData.name ?? ""
                                            color: root.messageTextColor
                                            font.pixelSize: Theme.type.meta.size
                                            wrapMode: Text.NoWrap
                                            elide: Text.ElideMiddle
                                        }
                                        RowText {
                                            id: fileDetail
                                            visible: text.length > 0
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: sentFile.modelData.detail ?? ""
                                            color: root.mutedColor
                                            font.pixelSize: Theme.type.meta.size
                                            wrapMode: Text.NoWrap
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
                            // A message of images alone has no block.
                            visible: (row.text ?? "").length > 0
                            // The column's, which the Loader only gives the
                            // Column after it is made: a block that wrapped at
                            // another width first would move the rows under it.
                            width: body.width
                            // A collapsed message shows at most 176px.
                            height: (collapsed ? Math.min(176, userText.implicitHeight) : userText.implicitHeight) + 2 * Theme.space.md
                            radius: Theme.radiusLg
                            color: root.messageColor
                            border.width: 1
                            border.color: root.borderColor
                            clip: collapsed
                            Markdown {
                                id: userText
                                x: Theme.space.lg
                                y: Theme.space.md
                                width: body.width - 2 * Theme.space.lg
                                text: row.text ?? ""
                                lineBreaks: true
                                textColor: root.messageTextColor
                                linkPreviews: root.linkPreviews
                                onLinkActivated: (link, external) => root.linkActivated(link, external)
                            }
                        }
                        ActionLink {
                            objectName: "messageExpand"
                            visible: bubble.collapsible
                            text: bubble.collapsed ? qsTr("Show full message") : qsTr("Show less")
                            Accessible.role: Accessible.Button
                            Accessible.name: text
                            onClicked: root.showFull(row.rowId, bubble.collapsed)
                        }
                        // A message that did not reach the agent says why.
                        Pill {
                            visible: text.length > 0 && text !== "completed" && text !== "pending" && text !== "waiting"
                            text: row.status ?? ""
                            textColor: root.errorColor
                            color: Qt.alpha(root.errorColor, 0.08)
                            border.color: Qt.alpha(root.errorColor, 0.25)
                        }
                        // Where the time and actions sit when they always show;
                        // no height (nor spacing) where they float.
                        Item {
                            id: metaSlot
                            width: parent.width
                            height: root.alwaysShowMeta ? Theme.control.sm : 0
                        }
                    }
                    Rectangle {
                        objectName: "userMessageMeta"
                        readonly property bool floating: !root.alwaysShowMeta
                        // Over the block's top edge, at its right, kept
                        // inside the row so the pointer stays on it.
                        x: floating ? parent.width - width - Theme.space.md : 0
                        y: floating ? Math.max(0, bubble.y - height / 2) : metaSlot.y
                        width: userMeta.width + (floating ? 2 * Theme.space.xxs : 0)
                        height: Theme.control.sm + (floating ? 2 * Theme.space.xxs : 0)
                        radius: Theme.radiusMd
                        color: floating ? Theme.palette.color("surfaceOverlay", "#22262e") : "transparent"
                        border.width: floating ? 1 : 0
                        border.color: Theme.palette.color("borderStrong", "#343a44")
                        opacity: row.showMeta ? 1 : 0
                        Behavior on opacity {
                            NumberAnimation {
                                duration: 200
                                easing.type: Easing.OutCubic
                            }
                        }
                        Row {
                            id: userMeta
                            anchors.centerIn: parent
                            height: Theme.control.sm
                            leftPadding: parent.floating ? Theme.space.sm : 0
                            spacing: Theme.space.sm
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
            }

            Component {
                id: assistantMessage
                Column {
                    // What it keeps blank at its foot: its actions' line, while
                    // they wait for the pointer.
                    readonly property real tail: bottomPadding + (replyMeta.visible && !root.alwaysShowMeta ? replyMeta.height : 0)
                    leftPadding: Theme.space.xs
                    rightPadding: Theme.space.xs
                    topPadding: Theme.space.xxs
                    // Before a divider, its actions' line is the space over it.
                    bottomPadding: row.beforeMarker && replyMeta.visible ? 0 : Theme.space.xxs
                    Markdown {
                        // Over the row's files and actions, for "Cite".
                        z: 1
                        width: parent.width - 2 * Theme.space.xs
                        // A finished reply with no text says so; one still being
                        // written is not empty yet (AssistantTimelineRow).
                        text: (row.text ?? "").length > 0 || row.streaming === true ? (row.text ?? "") : qsTr("(empty response)")
                        streaming: row.streaming ?? false
                        citable: root.citable && row.streaming !== true && !!row.messageId
                        linkPreviews: root.linkPreviews
                        onLinkActivated: (link, external) => root.linkActivated(link, external)
                        onCited: selector => root.cited(row.messageId, selector)
                        runnable: root.runnable
                        onRunCommand: command => root.runCommand(command)
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
                        width: parent.width - 2 * Theme.space.xs
                        height: filesCard.y + filesCard.height
                        Rectangle {
                            id: filesCard
                            y: Theme.space.lg
                            width: parent.width
                            height: filesColumn.implicitHeight
                            radius: Theme.radiusMd
                            color: root.surfaceColor
                            border.width: 1
                            border.color: root.borderColor
                            Column {
                                id: filesColumn
                                width: parent.width
                                Item {
                                    width: parent.width
                                    height: Theme.control.lg
                                    // How many files and lines; a count of none is left out (DiffStatLabel).
                                    Row {
                                        objectName: "changedFilesHeading"
                                        x: Theme.space.md
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.space.md
                                        RowText {
                                            text: changedFiles.changed.length === 1 ? qsTr("1 changed file") : qsTr("%1 changed files").arg(changedFiles.changed.length)
                                            font.pixelSize: Theme.type.meta.size
                                            font.weight: Font.Medium
                                            wrapMode: Text.NoWrap
                                        }
                                        Row {
                                            readonly property var totals: changedFiles.changed.reduce((sum, file) => [sum[0] + (file.additions ?? 0), sum[1] + (file.deletions ?? 0)], [0, 0])
                                            spacing: Theme.space.xs
                                            RowText {
                                                visible: parent.totals[0] > 0
                                                text: "+" + parent.totals[0]
                                                color: root.successColor
                                                font.family: root.monoFamily
                                                font.pixelSize: Theme.type.meta.size
                                                font.features: {
                                                    "tnum": 1
                                                }
                                            }
                                            RowText {
                                                visible: parent.totals[1] > 0
                                                text: "-" + parent.totals[1]
                                                color: root.errorColor
                                                font.family: root.monoFamily
                                                font.pixelSize: Theme.type.meta.size
                                                font.features: {
                                                    "tnum": 1
                                                }
                                            }
                                        }
                                    }
                                    IconButton {
                                        objectName: "changedFoldersToggle"
                                        visible: changedFiles.nested
                                        anchors.right: openDiff.left
                                        anchors.rightMargin: Theme.space.xs
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
                                        anchors.rightMargin: Theme.space.sm
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: openDiffRow.implicitWidth + 2 * Theme.space.sm
                                        height: Theme.control.sm
                                        radius: Theme.radiusSm
                                        color: openDiffHover.hovered ? root.hoverColor : "transparent"
                                        Accessible.role: Accessible.Button
                                        Accessible.name: qsTr("Open diff")
                                        Row {
                                            id: openDiffRow
                                            anchors.centerIn: parent
                                            spacing: Theme.space.sm
                                            ShellIcon {
                                                anchors.verticalCenter: parent.verticalCenter
                                                name: "file-diff"
                                                size: Theme.icon.sm
                                                color: openDiffHover.hovered ? root.textColor : root.mutedColor
                                            }
                                            RowText {
                                                // The web drops the words below 24rem.
                                                visible: filesCard.width >= 384
                                                text: qsTr("Open diff")
                                                color: openDiffHover.hovered ? root.textColor : root.mutedColor
                                                font.pixelSize: Theme.type.meta.size
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
                                    x: Theme.space.sm
                                    width: parent.width - 2 * Theme.space.sm
                                    bottomPadding: Theme.space.sm
                                    Repeater {
                                        model: ChangedFilesTree.rows(changedFiles.changed, changedFiles.open.all, changedFiles.open.folders)
                                        delegate: Rectangle {
                                            id: changedFile
                                            required property var modelData
                                            readonly property bool folder: modelData.kind === "directory"
                                            objectName: folder ? "changedFolder" : "changedFile"
                                            width: parent.width
                                            height: Theme.control.md
                                            radius: Theme.radiusSm
                                            color: changedFileHover.hovered ? root.hoverColor : "transparent"
                                            Accessible.role: Accessible.Button
                                            Accessible.name: modelData.path
                                            Accessible.onPressAction: changedFile.activate()
                                            function activate() {
                                                if (changedFile.folder)
                                                    root.toggleFolder(row.rowId, changedFile.modelData.path);
                                                else
                                                    root.fileActivated(changedFile.modelData.path, "diff", row.rowId);
                                            }
                                            ShellChevron {
                                                id: folderChevron
                                                visible: changedFile.folder
                                                x: Theme.space.sm + changedFile.modelData.depth * Theme.space.md
                                                anchors.verticalCenter: parent.verticalCenter
                                                direction: "right"
                                                size: Theme.icon.sm
                                                rotation: changedFile.modelData.expanded ? 90 : 0
                                                color: Theme.palette.color("inkTertiary", "#8b919e")
                                            }
                                            ShellIcon {
                                                id: fileIcon
                                                // A file sits under its folder's name, past the chevron.
                                                x: folderChevron.x + (changedFiles.nested ? Theme.icon.sm + Theme.space.sm : 0)
                                                anchors.verticalCenter: parent.verticalCenter
                                                name: !changedFile.folder ? "file" : changedFile.modelData.expanded ? "folder" : "folder-closed"
                                                size: Theme.icon.md
                                                color: Theme.palette.color("inkTertiary", "#8b919e")
                                            }
                                            RowText {
                                                x: fileIcon.x + Theme.icon.md + Theme.space.sm
                                                width: Math.max(0, fileStat.x - x - Theme.space.sm)
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: changedFile.modelData.name
                                                color: changedFile.folder ? (changedFileHover.hovered ? Theme.palette.color("inkSecondary", "#b8bdc7") : root.mutedColor) : changedFileHover.hovered ? root.textColor : Theme.palette.color("inkSecondary", "#b8bdc7")
                                                font.family: root.monoFamily
                                                font.pixelSize: changedFile.folder ? Theme.type.caption.size : Theme.type.meta.size
                                                wrapMode: Text.NoWrap
                                                elide: Text.ElideMiddle
                                            }
                                            Row {
                                                id: fileStat
                                                anchors.right: parent.right
                                                anchors.rightMargin: Theme.space.sm
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: Theme.space.xs
                                                RowText {
                                                    visible: changedFile.modelData.additions > 0
                                                    text: "+" + changedFile.modelData.additions
                                                    color: root.successColor
                                                    font.family: root.monoFamily
                                                    font.pixelSize: Theme.type.caption.size
                                                    font.features: {
                                                        "tnum": 1
                                                    }
                                                }
                                                RowText {
                                                    visible: changedFile.modelData.deletions > 0
                                                    text: "-" + changedFile.modelData.deletions
                                                    color: root.errorColor
                                                    font.family: root.monoFamily
                                                    font.pixelSize: Theme.type.caption.size
                                                    font.features: {
                                                        "tnum": 1
                                                    }
                                                }
                                            }
                                            HoverHandler {
                                                id: changedFileHover
                                                cursorShape: Qt.PointingHandCursor
                                            }
                                            TapHandler {
                                                onTapped: changedFile.activate()
                                            }
                                            // A file's own actions, where the environment can find it.
                                            TapHandler {
                                                acceptedButtons: Qt.RightButton
                                                enabled: !changedFile.folder && root.locatable
                                                onTapped: {
                                                    changedFileMenu.path = changedFile.modelData.path;
                                                    changedFileMenu.popup(changedFile);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // Its actions and time, on its settled turn's last reply.
                    Row {
                        id: replyMeta
                        visible: row.meta === true && row.streaming !== true
                        topPadding: row.beforeMarker ? 0 : Theme.space.sm
                        height: topPadding + Theme.control.sm
                        spacing: Theme.space.sm
                        opacity: row.showMeta ? 1 : 0
                        Behavior on opacity {
                            NumberAnimation {
                                duration: 200
                                easing.type: Easing.OutCubic
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
                            iconUrl: String(entry.iconUrl ?? ""),
                            iconUrlDark: String(entry.iconUrlDark ?? ""),
                            iconId: entry.iconId ?? "",
                            time: entry.time ?? "",
                            label: entry.label ?? "",
                            detail: entry.detail ?? "",
                            command: entry.command ?? "",
                            path: entry.path ?? "",
                            exited: entry.exitCode !== undefined && entry.exitCode !== null,
                            exitCode: entry.exitCode ?? 0,
                            preview: entry.preview ?? "",
                            // The rest of the details, as one value a list model keeps.
                            extra: JSON.stringify({
                                matches: root.list(entry.matches),
                                results: root.list(entry.results),
                                changes: root.list(entry.changes),
                                additions: entry.additions,
                                deletions: entry.deletions,
                                diffPath: entry.diffPath ?? "",
                                viewedPath: entry.viewedPath ?? "",
                                imageId: entry.imageId ?? "",
                                imageUrl: String(entry.imageUrl ?? "")
                            })
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
                    // A running turn's group folds into one live row: its
                    // latest call (what the agent is doing now, changing as
                    // calls land; no animation) and "+N previous tool calls",
                    // which opens into every call.
                    readonly property bool merged: (row.hiddenCount ?? 0) > 0 && row.expanded !== true && summary.length === 0 && calls.count > 0
                    readonly property var latest: merged ? calls.get(calls.count - 1) : null
                    // What a settled group did, the running group's live row,
                    // or "Show fewer tool calls" once it is open
                    // (WorkGroupToggleTimelineRow).
                    WorkLine {
                        id: groupToggle
                        objectName: "workGroupToggle"
                        readonly property bool failed: workGroup.latest !== null && (workGroup.latest.status === "failed" || workGroup.latest.statusLabel === qsTr("Failed"))
                        visible: (row.hiddenCount ?? 0) > 0
                        width: parent.width
                        iconName: workGroup.latest !== null ? (workGroup.latest.icon || "hammer") : "hammer"
                        iconSource: workGroup.latest === null ? "" : Theme.appearance === "light" ? workGroup.latest.iconUrl : workGroup.latest.iconUrlDark
                        iconTint: row.model.summaryFailed === true || failed ? Qt.alpha(root.toolErrorColor, 0.4) : root.iconColor
                        label: workGroup.latest !== null ? workGroup.latest.label : workGroup.summary.length > 0 ? workGroup.summary : row.expanded ? qsTr("Show fewer tool calls") : qsTr("+%1 previous tool calls").arg(row.hiddenCount)
                        labelElide: workGroup.latest !== null && (workGroup.latest.path ?? "").length > 0 ? Text.ElideMiddle : Text.ElideRight
                        preview: workGroup.latest?.preview ?? ""
                        interactive: true
                        Accessible.name: workGroup.merged ? qsTr("%1, +%2 previous tool calls").arg(label).arg(row.hiddenCount) : label
                        onClicked: root.toggle(row.rowId)
                        RowText {
                            objectName: "workGroupStatus"
                            anchors.verticalCenter: parent.verticalCenter
                            visible: workGroup.merged && text.length > 0
                            text: workGroup.latest?.statusLabel ?? ""
                            wrapMode: Text.NoWrap
                            font.pixelSize: Theme.type.meta.size
                            color: groupToggle.failed ? root.toolErrorColor : root.mutedColor
                        }
                        RowText {
                            objectName: "workGroupCount"
                            anchors.verticalCenter: parent.verticalCenter
                            visible: workGroup.merged
                            text: qsTr("+%1 previous tool calls").arg(row.hiddenCount)
                            wrapMode: Text.NoWrap
                            font.pixelSize: Theme.type.meta.size
                            font.features: {
                                "tnum": 1
                            }
                            color: groupToggle.hovered ? root.textColor : root.mutedColor
                        }
                        Item {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Theme.icon.md
                            height: Theme.icon.md
                            ShellChevron {
                                anchors.centerIn: parent
                                direction: "right"
                                size: Theme.icon.sm
                                color: groupToggle.hovered ? root.textColor : root.mutedColor
                                rotation: row.expanded ? 90 : 0
                            }
                        }
                    }
                    // An open group scrolls in a window of its own
                    // (ExpandedWorkGroupEntries): it opens again where the
                    // user left it, and follows new calls only while they are
                    // at its end (shouldFollowWorkGroupAppend).
                    Flickable {
                        id: callsView
                        objectName: "workCalls"
                        readonly property bool windowed: row.expanded === true && contentHeight > height
                        // Folded into the group's live row (`merged`).
                        visible: !workGroup.merged
                        // Whether the end was in view before the last change.
                        property bool atEnd: true
                        property int seen: 0
                        width: parent.width
                        height: workGroup.merged ? 0 : row.expanded === true ? Math.min(contentHeight, root.openGroupHeight) : contentHeight
                        contentWidth: width
                        contentHeight: callsColumn.height
                        interactive: windowed
                        clip: windowed
                        boundsBehavior: Flickable.StopAtBounds
                        // The call at the top and how far into it the view is.
                        function anchor() {
                            for (let at = 0; at < callsRepeater.count; ++at) {
                                const item = callsRepeater.itemAt(at);
                                if (item && item.y + item.height > contentY)
                                    return { entryId: item.modelData.id, offset: contentY - item.y };
                            }
                            return null;
                        }
                        function restore() {
                            const saved = root.groupAnchors[row.rowId];
                            if (!saved || !windowed)
                                return false;
                            for (let at = 0; at < callsRepeater.count; ++at) {
                                const item = callsRepeater.itemAt(at);
                                if (item && item.modelData.id === saved.entryId) {
                                    contentY = Math.max(0, Math.min(item.y + saved.offset, contentHeight - height));
                                    return true;
                                }
                            }
                            return false;
                        }
                        // Opened: back to the saved place once its calls are laid out.
                        property bool restoring: false
                        function reopen() {
                            contentY = 0;
                            restoring = row.expanded === true;
                            atEnd = !restoring;
                            if (restoring)
                                Qt.callLater(settle);
                        }
                        function settle() {
                            if (!restoring || calls.count !== root.list(row.entries).length)
                                return;
                            callsColumn.forceLayout();
                            restoring = false;
                            seen = calls.count;
                            if (!restore())
                                atEnd = contentHeight - height - contentY <= 1;
                        }
                        Connections {
                            target: row
                            function onExpandedChanged() {
                                callsView.reopen();
                            }
                        }
                        Component.onCompleted: reopen()
                        onContentYChanged: {
                            if (!row.expanded || restoring)
                                return;
                            atEnd = contentHeight - height - contentY <= 1;
                            const at = anchor();
                            if (at)
                                root.groupAnchors[row.rowId] = at;
                        }
                        onContentHeightChanged: {
                            if (restoring) {
                                settle();
                                return;
                            }
                            // Only a call added moves the view, and only from the end.
                            if (row.expanded === true && calls.count > seen && seen > 0 && atEnd)
                                contentY = Math.max(0, contentHeight - height);
                            else if (row.expanded === true)
                                atEnd = contentHeight - height - contentY <= 1;
                            seen = calls.count;
                        }
                        Column {
                            id: callsColumn
                            width: callsView.width
                            Repeater {
                                id: callsRepeater
                                model: calls
                                delegate: Column {
                                    id: call
                                    // The call's fields, each of which changes on its own.
                                    required property var model
                                    readonly property var modelData: model
                                    // Kept on the row, so streamed output does not close it.
                                    readonly property bool open: row.openCalls[modelData.id] === true
                                    readonly property var extra: JSON.parse(modelData.extra || "{}")
                                    readonly property bool hasDetails: (modelData.detail ?? "").length > 0 || (modelData.command ?? "").length > 0 || (extra.matches ?? []).length > 0 || (extra.results ?? []).length > 0 || (extra.changes ?? []).length > 0 || (extra.diffPath ?? "").length > 0 || (extra.viewedPath ?? "").length > 0
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
                                        iconSource: Theme.appearance === "light" ? call.modelData.iconUrl : call.modelData.iconUrlDark
                                        // An app's icon is the environment's to serve.
                                        readonly property string iconId: call.modelData.iconId
                                        onIconIdChanged: if (iconId.length > 0 && root.model !== null && typeof root.model.loadAttachment === "function")
                                            root.model.loadAttachment(iconId)
                                        Component.onCompleted: iconIdChanged()
                                        iconTint: call.failed ? Qt.alpha(root.toolErrorColor, 0.4) : root.iconColor
                                        label: call.modelData.label ?? ""
                                        preview: call.modelData.preview ?? ""
                                        labelElide: (call.modelData.path ?? "").length > 0 ? Text.ElideMiddle : Text.ElideRight
                                        interactive: call.hasDetails
                                        copyText: [call.modelData.label ?? "", call.modelData.command ?? "", call.modelData.detail ?? ""].filter((part, at, parts) => part.length > 0 && parts.indexOf(part) === at).join("\n")
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
                                            font.pixelSize: Theme.type.meta.size
                                            color: call.failed ? root.toolErrorColor : root.mutedColor
                                        }
                                        Stamp {
                                            anchors.verticalCenter: parent.verticalCenter
                                            // ljos-allow(focus-hover-only): a call's time is a detail with no action; touch shows it always (alwaysShowMeta), and the timeline's rows take no keyboard focus to show it on
                                            visible: text.length > 0 && (callLine.hovered || root.alwaysShowMeta)
                                            rowId: row.rowId
                                            entryId: call.modelData.id ?? ""
                                            text: call.modelData.time ?? ""
                                        }
                                        Item {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: Theme.icon.md
                                            height: Theme.icon.md
                                            ShellChevron {
                                                anchors.centerIn: parent
                                                visible: call.hasDetails
                                                direction: "right"
                                                size: Theme.icon.sm
                                                color: Theme.palette.color("inkTertiary", "#8b919e")
                                                rotation: call.open ? 90 : 0
                                            }
                                        }
                                    }
                                    Item {
                                        visible: call.open
                                        x: root.workInset
                                        width: parent.width - root.workInset
                                        height: detailsBox.y + detailsBox.height
                                        Rectangle {
                                            id: detailsBox
                                            y: call.panel ? Theme.space.xs : 0
                                            width: parent.width
                                            height: details.implicitHeight + details.y * 2
                                            radius: Theme.radiusSm
                                            color: call.panel ? Qt.alpha(root.mutedSurfaceColor, 0.4) : "transparent"
                                            Column {
                                                id: details
                                                x: call.panel ? Theme.space.md : Theme.space.xxs
                                                y: call.panel ? Theme.space.sm : Theme.space.xs
                                                width: parent.width - x * 2
                                                spacing: call.panel ? Theme.space.xs : Theme.space.md
                                                RowText {
                                                    visible: text.length > 0
                                                    width: parent.width
                                                    text: call.modelData.command ? "$ " + call.modelData.command : ""
                                                    textFormat: Text.PlainText
                                                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                                    font.family: root.monoFamily
                                                    font.pixelSize: Theme.type.caption.size
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
                                                    font.pixelSize: call.panel ? Theme.type.caption.size : Theme.type.body.size
                                                    lineHeight: 1.15
                                                    color: call.panel ? root.labelColor : root.textColor
                                                    maximumLineCount: 40
                                                    elide: Text.ElideRight
                                                }
                                                // A changed file: where, how much, its diff, and each change.
                                                Row {
                                                    visible: call.modelData.type === "file_change"
                                                    spacing: Theme.space.sm
                                                    RowText {
                                                        text: call.modelData.label ?? ""
                                                        wrapMode: Text.NoWrap
                                                        font.family: root.monoFamily
                                                        font.pixelSize: Theme.type.caption.size
                                                    }
                                                    RowText {
                                                        visible: call.extra.additions !== undefined
                                                        text: "+" + (call.extra.additions ?? 0)
                                                        color: root.successColor
                                                        font.family: root.monoFamily
                                                        font.pixelSize: Theme.type.caption.size
                                                    }
                                                    RowText {
                                                        visible: call.extra.deletions !== undefined
                                                        text: "-" + (call.extra.deletions ?? 0)
                                                        color: root.errorColor
                                                        font.family: root.monoFamily
                                                        font.pixelSize: Theme.type.caption.size
                                                    }
                                                    ActionLink {
                                                        objectName: "openCallDiff"
                                                        visible: (call.extra.diffPath ?? "").length > 0
                                                        text: qsTr("Open diff")
                                                        onClicked: root.fileActivated(call.extra.diffPath, "diff", row.rowId)
                                                    }
                                                }
                                                Repeater {
                                                    model: call.open ? call.extra.changes ?? [] : []
                                                    RowText {
                                                        required property string modelData
                                                        width: details.width
                                                        text: modelData
                                                        textFormat: Text.PlainText
                                                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                                        font.family: root.monoFamily
                                                        font.pixelSize: Theme.type.caption.size
                                                        color: root.mutedColor
                                                    }
                                                }
                                                // Where a search found its matches.
                                                Repeater {
                                                    model: call.open ? call.extra.matches ?? [] : []
                                                    Column {
                                                        required property var modelData
                                                        objectName: "searchMatch"
                                                        width: details.width
                                                        RowText {
                                                            width: parent.width
                                                            text: parent.modelData.location
                                                            textFormat: Text.PlainText
                                                            elide: Text.ElideMiddle
                                                            wrapMode: Text.NoWrap
                                                            font.family: root.monoFamily
                                                            font.pixelSize: Theme.type.caption.size
                                                        }
                                                        RowText {
                                                            visible: text.length > 0
                                                            width: parent.width
                                                            text: parent.modelData.preview
                                                            textFormat: Text.PlainText
                                                            elide: Text.ElideRight
                                                            wrapMode: Text.NoWrap
                                                            font.family: root.monoFamily
                                                            font.pixelSize: Theme.type.caption.size
                                                            color: root.mutedColor
                                                        }
                                                    }
                                                }
                                                // A web search's results: a link only to a web address.
                                                Repeater {
                                                    model: call.open ? call.extra.results ?? [] : []
                                                    Text {
                                                        id: webResult
                                                        required property var modelData
                                                        readonly property string link: modelData.url
                                                        objectName: "webResult"
                                                        width: details.width
                                                        text: modelData.title
                                                        textFormat: Text.PlainText
                                                        elide: Text.ElideRight
                                                        font.family: root.uiFamily
                                                        font.pixelSize: Theme.type.meta.size
                                                        font.underline: link.length > 0
                                                        color: link.length > 0 ? root.textColor : root.labelColor
                                                        Accessible.role: link.length > 0 ? Accessible.Link : Accessible.StaticText
                                                        Accessible.name: text
                                                        HoverHandler {
                                                            enabled: webResult.link.length > 0
                                                            cursorShape: Qt.PointingHandCursor
                                                        }
                                                        TapHandler {
                                                            enabled: webResult.link.length > 0
                                                            onTapped: root.linkActivated(webResult.link, false)
                                                        }
                                                    }
                                                }
                                                // An image the agent looked at, served from the
                                                // workspace; any other is named by its path.
                                                Image {
                                                    objectName: "viewedImage"
                                                    readonly property string imageId: call.extra.imageId ?? ""
                                                    visible: imageId.length > 0
                                                    width: Math.min(details.width, 320)
                                                    height: visible && status === Image.Ready ? Math.min(240, width * implicitHeight / Math.max(1, implicitWidth)) : 0
                                                    fillMode: Image.PreserveAspectFit
                                                    asynchronous: true
                                                    source: call.extra.imageUrl ?? ""
                                                    readonly property bool wanted: call.open && imageId.length > 0
                                                    onWantedChanged: if (wanted && root.model !== null && typeof root.model.loadAttachment === "function")
                                                        root.model.loadAttachment(imageId)
                                                    Component.onCompleted: wantedChanged()
                                                }
                                                RowText {
                                                    objectName: "viewedImagePath"
                                                    visible: text.length > 0
                                                    width: parent.width
                                                    text: (call.extra.imageId ?? "").length > 0 ? "" : call.extra.viewedPath ?? ""
                                                    textFormat: Text.PlainText
                                                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                                    font.family: root.monoFamily
                                                    font.pixelSize: Theme.type.caption.size
                                                    color: root.mutedColor
                                                }
                                                RowText {
                                                    objectName: "exitStatus"
                                                    visible: call.modelData.exited
                                                    text: qsTr("Process exited with code %1").arg(call.modelData.exitCode)
                                                    font.pixelSize: Theme.type.caption.size
                                                    color: call.modelData.exitCode === 0 ? root.successColor : root.errorColor
                                                }
                                            }
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
                // "Worked for 32s ›": the turn's work in one disclosure row,
                // in meta (TurnFoldTimelineRow). It opens in one step, no
                // height animation, so the rows under it stay put.
                Item {
                    implicitHeight: Theme.control.md
                    Row {
                        id: foldButton
                        objectName: "turnFold"
                        Accessible.role: Accessible.Button
                        Accessible.name: row.title ?? ""
                        Accessible.onPressAction: root.toggle(row.rowId)
                        anchors.verticalCenter: parent.verticalCenter
                        height: Theme.control.sm
                        leftPadding: Theme.space.xs
                        rightPadding: Theme.space.xs
                        spacing: Theme.space.xs
                        RowText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: row.title ?? ""
                            color: foldHover.hovered ? root.textColor : root.mutedColor
                            font.pixelSize: Theme.type.meta.size
                            font.features: {
                                "tnum": 1
                            }
                            wrapMode: Text.NoWrap
                        }
                        ShellChevron {
                            anchors.verticalCenter: parent.verticalCenter
                            direction: row.expanded ? "down" : "right"
                            size: Theme.icon.sm
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
                        anchors.rightMargin: Theme.space.sm
                        anchors.verticalCenter: foldButton.verticalCenter
                        visible: text.length > 0 && row.showMeta
                        rowId: row.rowId
                        text: row.time ?? ""
                    }
                }
            }

            Component {
                id: plan
                Rectangle {
                    // The card's padding (p-4, sm:p-5).
                    readonly property int pad: root.width >= 640 ? Theme.space.xl : Theme.space.lg
                    implicitHeight: planBody.implicitHeight + pad * 2 + 2 * Theme.space.xxs
                    color: "transparent"
                    // ProposedPlanCard, inset by its px-1 py-0.5 wrapper.
                    Rectangle {
                        x: Theme.space.xs
                        y: Theme.space.xxs
                        width: parent.width - 2 * Theme.space.xs
                        height: parent.height - 2 * Theme.space.xxs
                        radius: Theme.radiusXl
                        color: Qt.alpha(root.surfaceColor, 0.7)
                        border.color: Qt.alpha(root.borderColor, 0.8)
                    }
                    Column {
                        id: planBody
                        x: Theme.space.xs + parent.pad
                        y: Theme.space.xxs + parent.pad
                        width: parent.width - x * 2
                        spacing: Theme.space.lg
                        Row {
                            width: parent.width
                            spacing: Theme.space.sm
                            Rectangle {
                                id: planBadge
                                anchors.verticalCenter: parent.verticalCenter
                                width: planBadgeText.implicitWidth + 2 * Theme.space.sm
                                height: Theme.control.sm
                                radius: Theme.radiusSm
                                color: root.secondaryColor
                                RowText {
                                    id: planBadgeText
                                    anchors.centerIn: parent
                                    text: qsTr("Plan")
                                    color: root.secondaryTextColor
                                    font.pixelSize: Theme.type.meta.size
                                    font.weight: Font.Medium
                                    wrapMode: Text.NoWrap
                                }
                            }
                            RowText {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - planBadge.width - 8
                                text: row.title ?? ""
                                font.pixelSize: Theme.type.body.size
                                font.weight: Font.Medium
                                wrapMode: Text.NoWrap
                                elide: Text.ElideRight
                            }
                        }
                        Markdown {
                            width: parent.width
                            text: row.text ?? ""
                            linkPreviews: root.linkPreviews
                            onLinkActivated: (link, external) => root.linkActivated(link, external)
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
                    Accessible.role: subagentRow.thread.length > 0 ? Accessible.Link : Accessible.StaticText
                    Accessible.name: [row.title, row.statusLabel, subagentRow.hasDetail ? row.text : ""].filter(part => (part ?? "").length > 0).join(", ")
                    Accessible.onPressAction: if (subagentRow.thread.length > 0)
                        root.threadActivated(subagentRow.thread)
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
                        x: Theme.space.sm
                        anchors.verticalCenter: parent.verticalCenter
                        width: Theme.control.sm
                        height: Theme.control.sm
                        radius: Theme.radiusPill
                        color: root.mutedSurfaceColor
                        border.color: Qt.alpha(root.borderColor, 0.7)
                        ShellIcon {
                            anchors.centerIn: parent
                            name: row.icon || "bot"
                            size: Theme.icon.sm
                            color: root.mutedColor
                        }
                        // The status dot, ringed in the page's colour.
                        Rectangle {
                            x: parent.width - width + Theme.space.xs
                            y: parent.height - height + Theme.space.xs
                            width: Theme.icon.sm
                            height: Theme.icon.sm
                            radius: Theme.radiusPill
                            color: subagentRow.dot
                            border.width: 2
                            border.color: root.canvasColor
                        }
                    }
                    Column {
                        id: subagentText
                        x: avatar.x + avatar.width + Theme.space.md
                        width: parent.width - x - Theme.space.sm
                        anchors.verticalCenter: parent.verticalCenter
                        Row {
                            width: parent.width
                            spacing: 8
                            RowText {
                                id: subagentTitle
                                width: Math.min(implicitWidth, parent.width - (subagentStatus.visible ? subagentStatus.width + 8 : 0))
                                text: row.title ?? ""
                                font.pixelSize: Theme.type.meta.size
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
                                font.pixelSize: Theme.type.caption.size
                                wrapMode: Text.NoWrap
                            }
                        }
                        RowText {
                            width: parent.width
                            objectName: "subagentDetail"
                            text: (subagentRow.agentModel.length > 0 ? subagentRow.agentModel + " · " : "") + (subagentRow.hasDetail ? row.text : (row.statusLabel ?? ""))
                            color: subagentRow.failed ? root.errorColor : root.mutedColor
                            font.pixelSize: Theme.type.caption.size
                            wrapMode: Text.NoWrap
                            elide: Text.ElideRight
                        }
                    }
                }
            }

            Component {
                id: thinking
                // A running turn's live row while no call says what the agent is doing.
                WorkLine {
                    objectName: "thinkingRow"
                    iconName: row.icon || "brain"
                    label: row.title ?? ""
                }
            }

            Component {
                id: error
                // The failure's heading, then its message.
                Column {
                    WorkLine {
                        id: errorLine
                        objectName: "errorLine"
                        width: parent.width
                        iconName: row.icon || "circle-alert"
                        // A usage limit is a wait, not a crash.
                        iconTint: row.model.warning === true ? root.warningColor : root.errorColor
                        label: row.title ?? ""
                        labelColor: row.model.warning === true ? root.warningColor : root.errorColor
                        labelWeight: Font.Medium
                        copyText: [row.title ?? "", row.text ?? ""].filter(part => part.length > 0).join("\n")
                        Stamp {
                            anchors.verticalCenter: parent.verticalCenter
                            // The activity log always says when a turn failed.
                            visible: text.length > 0 && (row.showMeta || root.holdToCopy)
                            rowId: row.rowId
                            text: row.time ?? ""
                        }
                    }
                    RowText {
                        visible: text.length > 0
                        x: root.workInset
                        width: parent.width - root.workInset
                        topPadding: Theme.space.xs
                        bottomPadding: Theme.space.xs
                        text: row.text ?? ""
                        textFormat: Text.PlainText
                        color: Theme.palette.color("inkSecondary", "#b8bdc7")
                        font.pixelSize: Theme.type.prose.size
                    }
                }
            }

            Component {
                id: workerResult
                // A delegated worker's report (the worker's title opens its thread, the result
                // opens on demand), set apart from the agent's own replies by a rule at its edge.
                Item {
                    id: workerCard
                    readonly property string thread: row.model.thread ?? ""
                    readonly property bool failed: row.icon === "circle-alert"
                    property bool open: false
                    objectName: "workerResultCard"
                    implicitHeight: workerColumn.height + 2 * Theme.space.sm
                    Rectangle {
                        width: Theme.space.xxs
                        height: parent.height - 2 * Theme.space.sm
                        y: Theme.space.sm
                        radius: Theme.radiusPill
                        color: workerCard.failed ? root.errorColor : Qt.alpha(root.mutedColor, 0.6)
                    }
                    Column {
                        id: workerColumn
                        x: Theme.space.lg
                        y: Theme.space.sm
                        width: parent.width - Theme.space.lg
                        spacing: Theme.space.xs
                        Row {
                            spacing: Theme.space.sm
                            height: Theme.icon.lg
                            ShellIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: row.icon ?? "zap"
                                size: Theme.icon.sm
                                color: root.mutedColor
                            }
                            RowText {
                                id: workerTitle
                                objectName: "workerResultTitle"
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.min(implicitWidth, Math.max(0, root.columnWidth - 100))
                                text: row.title ?? ""
                                color: workerLink.hovered ? root.textColor : root.mutedColor
                                font.pixelSize: Theme.type.meta.size
                                font.weight: Font.Medium
                                font.underline: workerLink.hovered
                                wrapMode: Text.NoWrap
                                elide: Text.ElideRight
                                Accessible.role: Accessible.Link
                                HoverHandler {
                                    id: workerLink
                                    cursorShape: Qt.PointingHandCursor
                                }
                                TapHandler {
                                    onTapped: root.threadActivated(workerCard.thread)
                                }
                            }
                            RowText {
                                objectName: "workerResultToggle"
                                anchors.verticalCenter: parent.verticalCenter
                                visible: (row.text ?? "").length > 0
                                text: workerCard.open ? qsTr("Hide result") : qsTr("Show result")
                                color: root.mutedColor
                                font.pixelSize: Theme.type.caption.size
                                Accessible.role: Accessible.Button
                                TapHandler {
                                    onTapped: workerCard.open = !workerCard.open
                                }
                            }
                        }
                        RowText {
                            objectName: "workerResultText"
                            visible: workerCard.open && (row.text ?? "").length > 0
                            width: parent.width
                            text: row.text ?? ""
                            textFormat: Text.PlainText
                            color: Theme.palette.color("inkSecondary", "#b8bdc7")
                            font.pixelSize: Theme.type.body.size
                        }
                    }
                }
            }

            Component {
                id: marker
                // One quiet line, centred in the column, with no rule
                // (TimelineSystemDivider); the rows around it keep it 24
                // above and 16 below.
                Item {
                    implicitWidth: root.columnWidth
                    implicitHeight: markerContent.height
                    readonly property real tail: 0
                    Row {
                        id: markerContent
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Theme.space.xs
                        RowText {
                            objectName: "markerTitle"
                            // A notification's title names a task, as long as its author made it.
                            width: Math.min(implicitWidth, Math.max(0, root.columnWidth - (markerDetail.visible ? markerDetail.width + markerContent.spacing : 0)))
                            text: row.title ?? ""
                            color: root.mutedColor
                            font.pixelSize: Theme.type.meta.size
                            wrapMode: Text.NoWrap
                            elide: Text.ElideRight
                        }
                        RowText {
                            id: markerDetail
                            visible: (row.text ?? "").length > 0
                            width: Math.min(implicitWidth, root.columnWidth / 2)
                            text: "· " + (row.text ?? "")
                            color: root.mutedColor
                            font.pixelSize: Theme.type.meta.size
                            wrapMode: Text.NoWrap
                            elide: Text.ElideRight
                            // One line: a detail of several would hang over the rows around it.
                            maximumLineCount: 1
                        }
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

    // The conversation has the keyboard (Tab to it): Page Up/Down page it.
    // Not when a click put it on message text inside, which Tab never reaches.
    Rectangle {
        objectName: "timelineFocus"
        anchors.fill: view
        visible: view.activeFocus && !view.tapped && view.Window.activeFocusItem?.selectByMouse === undefined
        color: "transparent"
        radius: Theme.radiusSm
        border.width: 1
        border.color: Theme.palette.color("focus", "#3b82f6")
    }

    // "Working for 12s" under the rows, a static
    // line redrawn once a second while the agent works; "Sending…" while the
    // user's message is on its way.
    Item {
        id: indicator
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Theme.control.md + Theme.space.sm
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
            height: Theme.control.md
            // The running turn's "Worked for": its time so far, in meta,
            // a second at a time.
            RowText {
                objectName: "workingLabel"
                x: Theme.space.xs
                anchors.verticalCenter: parent.verticalCenter
                height: Theme.control.sm
                verticalAlignment: Text.AlignVCenter
                color: root.mutedColor
                font.pixelSize: Theme.type.meta.size
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
        }
    }

    // Earlier turns are on their way: a static line over the top of the
    // rows, so nothing under it moves when it comes and goes.
    Rectangle {
        objectName: "loadingEarlier"
        visible: root.loadingEarlier
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: view.top
        anchors.topMargin: Theme.space.md
        width: earlierText.implicitWidth + 2 * Theme.space.sm
        height: Theme.control.sm
        radius: Theme.radiusPill
        color: root.canvasColor
        border.color: root.borderColor
        RowText {
            id: earlierText
            anchors.centerIn: parent
            text: qsTr("Loading earlier turns…")
            color: root.mutedColor
            font.pixelSize: Theme.type.meta.size
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

    // The rows fade out under the header above, rather than meeting it
    // with a cut line, once the view has left the start.
    Rectangle {
        objectName: "timelineTopEdge"
        visible: !view.atYBeginning
        anchors.horizontalCenter: view.horizontalCenter
        anchors.top: view.top
        width: root.columnWidth
        height: Theme.space.lg
        gradient: Gradient {
            GradientStop {
                position: 0
                color: root.canvasColor
            }
            GradientStop {
                position: 1
                color: Qt.alpha(root.canvasColor, 0)
            }
        }
    }

    // Under "Scroll to end": the rows fade into the canvas there, so the
    // control never reads as part of the text it floats over.
    Rectangle {
        objectName: "jumpToLatestBand"
        visible: jump.visible
        // The reading column's width, clear of the scroll bar at the edge.
        anchors.horizontalCenter: view.horizontalCenter
        width: root.columnWidth
        anchors.bottom: view.bottom
        height: jump.height + 2 * Theme.space.md
        gradient: Gradient {
            GradientStop {
                position: 0
                color: Qt.alpha(root.canvasColor, 0)
            }
            GradientStop {
                position: 0.5
                color: root.canvasColor
            }
        }
    }

    // Back to the latest output once the user scrolled away: floats
    // bottom-centre, 12px over the composer, and only while they are away
    // from the end. Where the end is already under it, it would only cover
    // the last lines, so it stays away.
    ShellButton {
        id: jump
        objectName: "jumpToLatest"
        visible: !view.following && view.count > 0 && view.originY + view.contentHeight - (view.contentY + view.height) > height + 2 * Theme.space.md
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: view.bottom
        anchors.bottomMargin: Theme.space.md
        height: Theme.control.md
        radius: Theme.radiusPill
        iconName: "chevron-down"
        iconSize: Theme.icon.sm
        text: qsTr("Scroll to end")
        font.pixelSize: Theme.type.meta.size
        Accessible.role: Accessible.Button
        Accessible.name: text
        Accessible.onPressAction: clicked()
        // Reached by Tab, but a click does not take the composer's focus.
        focusPolicy: Qt.TabFocus
        onClicked: root.scrollToEnd()
        // An overlay pill: the popover's surface, its strong border and a
        // still shadow, so it reads as a control over the message beneath it.
        background: Item {
            Rectangle {
                y: Theme.space.xxs
                width: parent.width
                height: parent.height
                radius: jump.radius
                color: Qt.alpha("black", Theme.appearance === "light" ? 0.12 : 0.4)
            }
            Rectangle {
                anchors.fill: parent
                radius: jump.radius
                color: jump.hovered || jump.down ? root.hoverColor : Theme.palette.color("surfaceOverlay", "#22262e")
                border.color: jump.visualFocus ? jump.focusRing : Theme.palette.color("borderStrong", "#343a44")
                border.width: 1
            }
        }
    }
}
