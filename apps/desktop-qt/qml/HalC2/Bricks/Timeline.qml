import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// A thread's timeline: the rows of a TimelineModel (Threads.timeline), or any
// model with its roles (rowId, kind, author, text, streaming, title, status,
// statusLabel, marker, entries, hiddenCount, expanded, files).
//
//   Timeline { anchors.fill: parent; model: Threads.timeline }
//
// The view follows new output while it is at the end. Scrolling away stops
// that and offers a way back to the latest output. Folds and tool call
// groups open and close through the model's toggle(rowId). A message offers
// Copy on hover, and an agent reply whose turn left a checkpoint offers
// Revert (revertRequested); files a reply changed or a tool call touched ask
// to be opened (fileActivated). What those do is the host's (ThreadView).
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

    readonly property color textColor: Theme.palette.color("text", "#e4e4e7")
    readonly property color mutedColor: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color borderColor: Theme.palette.color("border", "#27272a")
    readonly property color surfaceColor: Theme.palette.color("surface", "#141416")
    readonly property color accentColor: Theme.palette.color("accent", "#3b82f6")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
    readonly property color warningColor: Theme.palette.color("warning", "#f59e0b")
    readonly property string monoFamily: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
    readonly property string uiFamily: Theme.fontUi.length > 0 ? Theme.fontUi : Qt.application.font.family

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

    // A clickable line with a chevron, for folds and "+N previous tool calls".
    component Disclosure: Item {
        id: disclosure
        property string text
        property bool open
        signal clicked
        implicitHeight: 24
        implicitWidth: disclosureRow.implicitWidth
        Row {
            id: disclosureRow
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            RowText {
                text: disclosure.open ? "▾" : "▸"
                color: root.mutedColor
                wrapMode: Text.NoWrap
            }
            RowText {
                text: disclosure.text
                color: disclosureHover.hovered ? root.textColor : root.mutedColor
                wrapMode: Text.NoWrap
            }
        }
        HoverHandler {
            id: disclosureHover
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            onTapped: disclosure.clicked()
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
        spacing: 12
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
            // The tool calls whose details are open, by id.
            property var openCalls: ({})
            // A message's actions show while the pointer is over it; their
            // line is always there, so hovering moves nothing.
            readonly property bool showActions: rowHover.hovered && row.streaming !== true

            HoverHandler {
                id: rowHover
            }

            width: ListView.view.width
            height: body.item ? body.item.implicitHeight : 0

            Loader {
                id: body
                x: 16
                width: row.width - 32
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
                    RowText {
                        visible: text.length > 0
                        anchors.right: parent.right
                        text: row.marker ?? ""
                        color: root.mutedColor
                        font.pixelSize: 12
                    }
                    Rectangle {
                        anchors.right: parent.right
                        width: Math.min(parent.width * 0.85, userText.implicitWidth + 24)
                        height: userText.implicitHeight + 16
                        radius: Theme.radius
                        color: root.surfaceColor
                        border.color: root.borderColor
                        Markdown {
                            id: userText
                            x: 12
                            y: 8
                            width: Math.min(implicitWidth, body.width * 0.85 - 24)
                            text: row.text ?? ""
                        }
                    }
                    Row {
                        anchors.right: parent.right
                        height: 16
                        spacing: 12
                        opacity: row.showActions ? 1 : 0
                        ActionLink {
                            objectName: "copyMessage"
                            text: qsTr("Copy")
                            visible: root.canCopy
                            enabled: row.showActions
                            onClicked: root.copy(row.rowId)
                        }
                    }
                }
            }

            Component {
                id: assistantMessage
                Column {
                    spacing: 6
                    Markdown {
                        width: parent.width
                        text: row.text ?? ""
                    }
                    Column {
                        visible: root.list(row.files).length > 0
                        width: parent.width
                        spacing: 2
                        RowText {
                            text: qsTr("Changed files")
                            color: root.mutedColor
                            font.pixelSize: 12
                        }
                        Repeater {
                            model: root.list(row.files)
                            delegate: Row {
                                required property var modelData
                                spacing: 8
                                RowText {
                                    objectName: "changedFile"
                                    text: modelData.path
                                    font.family: root.monoFamily
                                    font.pixelSize: 12
                                    wrapMode: Text.NoWrap
                                    font.underline: changedFileHover.hovered
                                    HoverHandler {
                                        id: changedFileHover
                                        cursorShape: Qt.PointingHandCursor
                                    }
                                    TapHandler {
                                        onTapped: root.fileActivated(modelData.path, "diff", row.rowId)
                                    }
                                }
                                RowText {
                                    text: "+" + modelData.additions
                                    color: Theme.palette.color("success", "#34d399")
                                    font.pixelSize: 12
                                }
                                RowText {
                                    text: "-" + modelData.deletions
                                    color: root.errorColor
                                    font.pixelSize: 12
                                }
                            }
                        }
                    }
                    Row {
                        height: 16
                        spacing: 12
                        opacity: row.showActions ? 1 : 0
                        ActionLink {
                            objectName: "copyMessage"
                            text: qsTr("Copy")
                            visible: root.canCopy
                            enabled: row.showActions
                            onClicked: root.copy(row.rowId)
                        }
                        ActionLink {
                            objectName: "revertToTurn"
                            text: qsTr("Revert to here")
                            // Asked again each time the pointer comes over the reply.
                            visible: row.showActions && root.revertable(row.rowId)
                            onClicked: root.revertRequested(row.rowId)
                        }
                    }
                }
            }

            Component {
                id: work
                Column {
                    spacing: 2
                    Disclosure {
                        visible: (row.hiddenCount ?? 0) > 0
                        open: row.expanded === true
                        text: row.expanded ? qsTr("Show fewer tool calls") : qsTr("+%1 previous tool calls").arg(row.hiddenCount)
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
                            width: parent.width
                            spacing: 2
                            Item {
                                width: parent.width
                                height: 22
                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 6
                                    RowText {
                                        text: call.hasDetails ? (call.open ? "▾" : "▸") : "•"
                                        color: root.mutedColor
                                        wrapMode: Text.NoWrap
                                    }
                                    RowText {
                                        text: call.modelData.label
                                        color: root.mutedColor
                                        wrapMode: Text.NoWrap
                                        elide: Text.ElideRight
                                        width: Math.min(implicitWidth, call.width - 140)
                                    }
                                    ActionLink {
                                        id: openLink
                                        objectName: "openFile"
                                        visible: (call.modelData.path ?? "").length > 0
                                        text: qsTr("Open")
                                        onClicked: root.fileActivated(call.modelData.path, "files", row.rowId)
                                    }
                                    RowText {
                                        visible: text.length > 0
                                        text: call.modelData.statusLabel ?? ""
                                        wrapMode: Text.NoWrap
                                        font.pixelSize: 12
                                        color: text === qsTr("Failed") ? root.errorColor : text === qsTr("Running") ? root.accentColor : root.warningColor
                                    }
                                }
                                TapHandler {
                                    enabled: call.hasDetails
                                    onTapped: eventPoint => {
                                        // Open takes its own tap.
                                        if (openLink.visible && openLink.contains(openLink.mapFromItem(parent, eventPoint.position)))
                                            return;
                                        const next = Object.assign({}, row.openCalls);
                                        next[call.modelData.id] = !call.open;
                                        row.openCalls = next;
                                    }
                                }
                            }
                            Rectangle {
                                visible: call.open
                                width: parent.width
                                height: visible ? details.implicitHeight + 12 : 0
                                radius: Theme.radius
                                color: root.surfaceColor
                                border.color: root.borderColor
                                Column {
                                    id: details
                                    x: 8
                                    y: 6
                                    width: parent.width - 16
                                    spacing: 4
                                    RowText {
                                        visible: text.length > 0
                                        width: parent.width
                                        text: call.modelData.command ? "$ " + call.modelData.command : ""
                                        font.family: root.monoFamily
                                        font.pixelSize: 12
                                    }
                                    RowText {
                                        visible: text.length > 0
                                        width: parent.width
                                        text: call.modelData.detail ?? ""
                                        font.family: root.monoFamily
                                        font.pixelSize: 12
                                        color: root.mutedColor
                                        maximumLineCount: 40
                                        elide: Text.ElideRight
                                    }
                                    RowText {
                                        visible: call.modelData.exitCode !== undefined
                                        text: qsTr("Exit code %1").arg(call.modelData.exitCode)
                                        font.pixelSize: 12
                                        color: root.mutedColor
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Component {
                id: fold
                Disclosure {
                    text: row.title ?? ""
                    open: row.expanded === true
                    onClicked: root.toggle(row.rowId)
                }
            }

            Component {
                id: plan
                Rectangle {
                    implicitHeight: planBody.implicitHeight + 24
                    radius: Theme.radius
                    color: root.surfaceColor
                    border.color: root.borderColor
                    Column {
                        id: planBody
                        x: 12
                        y: 12
                        width: parent.width - 24
                        spacing: 6
                        RowText {
                            text: row.title ?? ""
                            font.bold: true
                            width: parent.width
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
                Rectangle {
                    implicitHeight: subagentBody.implicitHeight + 16
                    radius: Theme.radius
                    color: "transparent"
                    border.color: root.borderColor
                    Column {
                        id: subagentBody
                        x: 12
                        y: 8
                        width: parent.width - 24
                        spacing: 2
                        RowLayout {
                            width: parent.width
                            RowText {
                                text: row.title ?? ""
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                wrapMode: Text.NoWrap
                            }
                            RowText {
                                text: row.statusLabel ?? ""
                                color: row.statusLabel === qsTr("Failed") ? root.errorColor : root.mutedColor
                                font.pixelSize: 12
                            }
                        }
                        RowText {
                            visible: text.length > 0
                            width: parent.width
                            text: row.text ?? ""
                            color: root.mutedColor
                            maximumLineCount: 3
                            elide: Text.ElideRight
                        }
                    }
                }
            }

            Component {
                id: error
                RowText {
                    text: row.text && row.text.length > 0 ? row.text : row.title
                    color: root.errorColor
                }
            }

            Component {
                id: marker
                RowText {
                    horizontalAlignment: Text.AlignHCenter
                    color: root.mutedColor
                    font.pixelSize: 12
                    text: row.text && row.text.length > 0 ? row.title + " · " + row.text : (row.title ?? "")
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

    // A static line, redrawn once a second while the agent works.
    Item {
        id: indicator
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 28
        visible: root.working
        property int tick: 0
        Timer {
            interval: 1000
            repeat: true
            running: indicator.visible && root.visible
            onTriggered: indicator.tick++
        }
        Row {
            x: 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 6
                height: 6
                radius: 3
                color: root.accentColor
            }
            RowText {
                objectName: "workingLabel"
                color: root.mutedColor
                wrapMode: Text.NoWrap
                text: {
                    indicator.tick;
                    return root.model && typeof root.model.workingLabel === "function" ? root.model.workingLabel() : qsTr("Working");
                }
            }
        }
    }

    // Back to the latest output once the user scrolled away.
    Rectangle {
        id: jump
        objectName: "jumpToLatest"
        visible: !view.following && view.count > 0
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: view.bottom
        anchors.bottomMargin: 12
        width: jumpLabel.implicitWidth + 24
        height: 28
        radius: 14
        color: root.surfaceColor
        border.color: root.borderColor
        RowText {
            id: jumpLabel
            anchors.centerIn: parent
            text: qsTr("↓ Scroll to end")
            wrapMode: Text.NoWrap
        }
        HoverHandler {
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            onTapped: root.scrollToEnd()
        }
    }
}
