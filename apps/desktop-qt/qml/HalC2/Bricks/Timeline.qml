import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// A thread's timeline: the rows of a TimelineModel (Threads.timeline), or any
// model with its roles (rowId, kind, author, text, streaming, title, status,
// statusLabel, marker, entries, hiddenCount, expanded, files, time, icon,
// intent, attribution).
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
// do is the host's (ThreadView).
Item {
    id: root

    property var model: null
    // Whether the agent is working and what the indicator says; the model's
    // own when it has them.
    property bool working: root.model !== null && root.model.working === true
    // Whether the view keeps the latest output in view.
    readonly property alias following: view.following
    // Whether the list says it is loading or its node cannot be reached;
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
    readonly property string uiFamily: Theme.fontUi.length > 0 ? Theme.fontUi : Qt.application.font.family
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
        font.pixelSize: 13
        wrapMode: Text.Wrap
    }

    component Markdown: TextEdit {
        color: root.textColor
        font.family: root.uiFamily
        font.pixelSize: 14
        textFormat: TextEdit.MarkdownText
        wrapMode: TextEdit.Wrap
        readOnly: true
        selectByMouse: true
        selectionColor: root.accentColor
        onLinkActivated: link => root.linkActivated(link)
        HoverHandler {
            cursorShape: parent.hoveredLink.length > 0 ? Qt.PointingHandCursor : Qt.IBeamCursor
        }
    }

    // A small text button under a message.
    component ActionLink: Text {
        id: action
        signal clicked
        color: actionHover.hovered ? root.textColor : root.mutedColor
        font.family: root.uiFamily
        font.pixelSize: 12
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
        font.pixelSize: 12
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
            font.pixelSize: 10
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
            font.pixelSize: 14
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

        property bool following: true
        property bool positioning: false

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

        anchors.fill: parent
        anchors.bottomMargin: indicator.visible ? indicator.height : 0
        clip: true
        topMargin: 12
        bottomMargin: 12
        boundsBehavior: Flickable.StopAtBounds
        model: root.model
        ScrollBar.vertical: ScrollBar {
            id: scrollBar
        }

        // Only the user's own scrolling (wheel, drag, keys, scroll bar)
        // decides whether the view follows; the list settling its layout or
        // growing below the end does not.
        onContentYChanged: {
            if (!positioning && (moving || dragging || scrollBar.pressed))
                following = nearEnd();
        }
        onMovementEnded: following = nearEnd()
        onContentHeightChanged: if (following)
            Qt.callLater(stick)
        onCountChanged: if (following)
            Qt.callLater(stick)
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
            // The tool calls whose details are open, by id.
            property var openCalls: ({})
            // Whether the row's time and actions show: only this row's
            // pointer changes it.
            readonly property bool showMeta: root.alwaysShowMeta || rowHover.hovered
            // The space under the row, by kind (the web's row padding).
            readonly property int gap: {
                switch (row.kind) {
                case "message":
                    return row.author !== "user" && row.streaming === true ? 8 : 16;
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
            height: body.item ? body.item.implicitHeight + row.gap : 0

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
                    // Who sent it, when not the user.
                    RowText {
                        visible: text.length > 0
                        anchors.right: parent.right
                        anchors.rightMargin: 4
                        text: row.attribution ?? ""
                        color: Qt.alpha(root.mutedColor, 0.7)
                        font.pixelSize: 11
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
                            font.pixelSize: 12
                            wrapMode: Text.NoWrap
                            HoverHandler {
                                id: intentHover
                            }
                            ToolTip.visible: intentHover.hovered && (row.marker ?? "").length > 0
                            ToolTip.delay: 500
                            ToolTip.text: row.marker ?? ""
                        }
                    }
                    Rectangle {
                        anchors.right: parent.right
                        width: Math.min(parent.width * 0.8, userText.implicitWidth + 24)
                        height: userText.implicitHeight + 24
                        radius: 16
                        color: root.messageColor
                        Markdown {
                            id: userText
                            x: 12
                            y: 12
                            width: Math.min(implicitWidth, body.width * 0.8 - 24)
                            text: row.text ?? ""
                        }
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
                        width: parent.width - 8
                        text: row.text ?? ""
                    }
                    // The files the reply's turn changed (ChangedFilesCard).
                    Item {
                        id: changedFiles
                        readonly property var changed: root.list(row.files)
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
                                            font.pixelSize: 12
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
                                                font.pixelSize: 12
                                            }
                                            RowText {
                                                text: "-" + parent.totals[1]
                                                color: root.errorColor
                                                font.family: root.monoFamily
                                                font.pixelSize: 12
                                            }
                                        }
                                    }
                                    // The turn's diff, from its first file.
                                    Rectangle {
                                        id: openDiff
                                        readonly property var first: changedFiles.changed[0]
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
                                                font.pixelSize: 12
                                                wrapMode: Text.NoWrap
                                            }
                                        }
                                        HoverHandler {
                                            id: openDiffHover
                                            cursorShape: Qt.PointingHandCursor
                                        }
                                        TapHandler {
                                            onTapped: root.fileActivated(openDiff.first ? openDiff.first.path : "", "diff", row.rowId)
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
                                        model: changedFiles.changed
                                        delegate: Rectangle {
                                            id: changedFile
                                            required property var modelData
                                            objectName: "changedFile"
                                            width: parent.width
                                            height: 28
                                            radius: 6
                                            color: changedFileHover.hovered ? Qt.alpha(root.hoverColor, 0.6) : "transparent"
                                            ShellIcon {
                                                id: fileIcon
                                                x: 8
                                                anchors.verticalCenter: parent.verticalCenter
                                                name: "file"
                                                size: 14
                                                color: Qt.alpha(root.mutedColor, 0.7)
                                            }
                                            RowText {
                                                x: fileIcon.x + 22
                                                width: Math.max(0, fileStat.x - x - 8)
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: changedFile.modelData.path
                                                color: changedFileHover.hovered ? root.textColor : Qt.alpha(root.textColor, 0.85)
                                                font.family: root.monoFamily
                                                font.pixelSize: 12
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
                                                    font.pixelSize: 10
                                                }
                                                RowText {
                                                    text: "-" + changedFile.modelData.deletions
                                                    color: root.errorColor
                                                    font.family: root.monoFamily
                                                    font.pixelSize: 10
                                                }
                                            }
                                            HoverHandler {
                                                id: changedFileHover
                                                cursorShape: Qt.PointingHandCursor
                                            }
                                            TapHandler {
                                                onTapped: root.fileActivated(changedFile.modelData.path, "diff", row.rowId)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // Its actions and time, once it has finished streaming.
                    Row {
                        visible: row.streaming !== true
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
                    // "+N previous tool calls" (WorkGroupToggleTimelineRow).
                    WorkLine {
                        visible: (row.hiddenCount ?? 0) > 0
                        width: parent.width
                        iconName: "hammer"
                        label: row.expanded ? qsTr("Show fewer tool calls") : qsTr("+%1 previous tool calls").arg(row.hiddenCount)
                        interactive: true
                        onClicked: root.toggle(row.rowId)
                    }
                    Repeater {
                        model: root.list(row.entries)
                        delegate: Column {
                            id: call
                            required property var modelData
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
                                    font.pixelSize: 12
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
                                            font.pixelSize: 11
                                        }
                                        RowText {
                                            visible: text.length > 0
                                            width: parent.width
                                            text: call.modelData.detail ?? ""
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
                                            visible: call.modelData.exitCode !== undefined
                                            text: qsTr("Exit code %1").arg(call.modelData.exitCode)
                                            font.pixelSize: 11
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
                            font.pixelSize: 14
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
                                    font.pixelSize: 12
                                    font.weight: Font.Medium
                                    wrapMode: Text.NoWrap
                                }
                            }
                            RowText {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - planBadge.width - 8
                                text: row.title ?? ""
                                font.pixelSize: 14
                                font.weight: Font.Medium
                                wrapMode: Text.NoWrap
                                elide: Text.ElideRight
                            }
                        }
                        Markdown {
                            width: parent.width
                            text: row.text ?? ""
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
                    implicitHeight: Math.max(24, subagentText.implicitHeight) + 12
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
                                font.pixelSize: 12
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
                                font.pixelSize: 10
                                wrapMode: Text.NoWrap
                            }
                        }
                        RowText {
                            width: parent.width
                            text: subagentRow.hasDetail ? row.text : (row.statusLabel ?? "")
                            color: subagentRow.failed ? root.errorColor : root.mutedColor
                            font.pixelSize: 11
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
                        font.pixelSize: 14
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
                            font.pixelSize: 11
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
                            font.pixelSize: 11
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
                    return qsTr("This thread's node cannot be reached: %1").arg(root.model.problem ?? "");
                return qsTr("Loading…");
            }
        }
    }

    // "Working for 12s" under the rows (the web's working row), a static
    // line redrawn once a second while the agent works.
    Item {
        id: indicator
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 42
        visible: root.working
        property int tick: 0
        Timer {
            interval: 1000
            repeat: true
            running: indicator.visible && root.visible
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
                font.pixelSize: 14
                font.features: {
                    "tnum": 1
                }
                wrapMode: Text.NoWrap
                text: {
                    indicator.tick;
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
                font.pixelSize: 12
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
