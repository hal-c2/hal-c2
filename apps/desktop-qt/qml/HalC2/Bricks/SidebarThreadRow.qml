pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HalC2.Shell

// One thread (or draft) row of the Sidebar brick: the project's mark, the
// title, and under it "project · branch"; `slim` keeps the title alone (the
// shelves, and every row in a narrow window). The fixed slot on the right
// shows one thing: the section's actions while hovered or focused (unpin or
// snooze, and settle; wake; un-settle), else the jump key while its modifier
// is held, else the status icon, else the age.
Item {
    id: row

    required property var item
    required property bool active
    property bool slim: false
    property string projectName: ""
    // Whether line 2 names the project; a list of one project's threads leaves it to the mark.
    property bool projectInDetail: true
    // The project's icon as `projectIcons` publishes it; null draws a folder.
    property var projectIcon: null
    // Which sidebar group the row sits in: pinned, active, snoozed, settled
    // or draft. Decides the hover actions.
    property string section: "active"
    // Keyboard cursor: draws the focus ring and shows the actions.
    property bool focused: false
    // A row that may be under a finger: a finger's drag is left to the list,
    // which scrolls, and its long press asks for the menu a right click
    // opens. A mouse or trackpad still arranges the row by dragging it.
    property bool touch: false
    property double ageNow: Date.now()

    signal activated
    // Ctrl/Cmd+click adds the row to the selection, Shift+click selects the range to it.
    signal selectionToggled
    signal rangeSelected
    // A drag arranges the row: where the pointer is in the window while it
    // lasts, and whether it ended in a drop.
    signal dragMoved(real windowY)
    signal dragEnded(bool dropped)
    // Image files dropped on the row go to the thread's composer.
    signal filesDropped(var urls)
    signal menuRequested(real windowX, real windowY)
    signal settleRequested
    signal unsettleRequested
    signal snoozeRequested(real windowX, real windowY)
    signal unsnoozeRequested
    signal unpinRequested
    signal wokeDismissed

    readonly property color textColor: Theme.palette.color("ink", "#e4e4e7")
    readonly property color secondaryColor: Theme.palette.color("inkSecondary", "#b8bdc7")
    readonly property color tertiaryColor: Theme.palette.color("inkTertiary", "#8b919e")
    // Themes may colour the project and branch and mark the active row with
    // a bar; without those roles the text stays neutral and the project's
    // colour is only in its mark.
    readonly property color projectColor: Theme.palette.color("projectForeground", tertiaryColor)
    readonly property color branchColor: Theme.palette.color("branchForeground", tertiaryColor)
    readonly property color indicatorColor: Theme.palette.color("sidebarActiveIndicator", "transparent")
    readonly property color focusColor: Theme.palette.color("focus", "#3b82f6")
    readonly property bool draft: section === "draft"
    readonly property bool selected: item.selected === true
    readonly property bool woke: item.wokeAt !== null && item.wokeAt !== undefined
    readonly property bool parked: section === "snoozed" || section === "settled"
    // The thread's environment is unreachable: the row stays, says so, and
    // recedes until the environment comes back.
    readonly property bool offline: item.offline === true
    // The thread is on its way to another machine: the row says where to
    // until it is listed there.
    readonly property string movingTo: item.movingTo ?? ""
    readonly property bool canSettle: !draft && !parked && item.canSettle === true
    readonly property bool canSnooze: !draft && !parked && item.canSnooze === true
    readonly property bool pinned: !draft && item.pinned === true
    readonly property bool hasActions: !offline && (parked || pinned || canSettle || canSnooze)
    // The key that opens the row, shown in the status slot while the jump
    // modifier is held.
    readonly property string jumpLabel: item.jumpLabel ?? ""
    readonly property bool showActions: hasActions && (hover.hovered || focused)
    // What the status slot shows: "actions", "jump", "status" or "age".
    readonly property string slot: showActions ? "actions" : jumpLabel.length > 0 ? "jump" : statusIcon.length > 0 ? "status" : "age"
    // The status word for each state; empty when the
    // row is at rest, then the slot shows the age (or the wake time).
    readonly property string statusWord: {
        if (row.offline) {
            return qsTr("Offline");
        }
        if (row.movingTo.length > 0) {
            return qsTr("Moving to %1").arg(row.movingTo);
        }
        switch (item.status) {
        case "working":
            return item.workingLabel ? qsTr("Working %1").arg(item.workingLabel) : qsTr("Working");
        case "waiting":
            return qsTr("Waiting");
        case "approval":
            return qsTr("Approval");
        case "input":
            return qsTr("Input");
        case "limited":
            return qsTr("Limited");
        case "failed":
            return qsTr("Failed");
        }
        if (row.woke) {
            return qsTr("Woke");
        }
        if (item.unread === true) {
            return qsTr("Done");
        }
        return "";
    }
    readonly property string statusIcon: {
        if (row.offline) {
            return "cloud";
        }
        if (row.movingTo.length > 0) {
            return "arrow-right-left";
        }
        switch (item.status) {
        case "working":
            return "circle-dashed";
        case "waiting":
            return "pause";
        case "approval":
            return "shield";
        case "input":
            return "message-circle";
        case "limited":
            return "circle-alert";
        case "failed":
            return "circle-x";
        }
        if (row.woke) {
            return "alarm-clock";
        }
        if (item.unread === true) {
            return "circle-check";
        }
        return "";
    }
    readonly property color statusColor: {
        if (row.offline || row.movingTo.length > 0) {
            return row.tertiaryColor;
        }
        switch (item.status) {
        case "approval":
            return Theme.palette.color("warningForeground", "#f59e0b");
        case "input":
            return Theme.palette.color("accent", "#818cf8");
        case "working":
            return Theme.palette.color("info", "#38bdf8");
        case "waiting":
            return row.tertiaryColor;
        case "limited":
            return Theme.palette.color("warningForeground", "#f59e0b");
        case "failed":
            return Theme.palette.color("errorForeground", "#f87171");
        }
        if (row.woke) {
            return Theme.palette.color("warningForeground", "#f59e0b");
        }
        if (item.unread === true) {
            return Theme.palette.color("success", "#34d399");
        }
        return row.tertiaryColor;
    }
    readonly property bool showStatus: statusWord.length > 0
    // In-flight and read-ready rows recede: prominence is for rows that need
    // a human (done, failed, woke) and the one that is open.
    readonly property bool recedes: offline || !active && !woke && item.unread !== true && item.status !== "failed" && item.status !== "limited"
    // Titles keep the prompt's line breaks; the row shows them on one line,
    // so a multi-line title never overflows the card.
    readonly property string oneLineTitle: (item.title ?? "").replace(/\s+/g, " ").trim()
    readonly property string ageLabel: item.wakeLabel ? item.wakeLabel : relativeAge(item.timeAt ?? item.updatedAt, ageNow)
    // Line 2: "project · branch", either alone when the other is missing.
    readonly property string branchName: item.branch ?? ""
    readonly property string detailProject: projectInDetail ? projectName : ""
    readonly property bool hasDetail: detailProject.length > 0 || branchName.length > 0
    // DIRECTION's 44px slot: two 20px actions and the gap between them.
    readonly property int slotWidth: Theme.icon.lg * 2 + Theme.space.xs
    // The slot at rest, holding only the age: 28px, or the age's own width
    // when that is less, so the title gets the rest.
    readonly property int restingSlotWidth: Theme.icon.lg + Theme.space.sm

    function relativeAge(iso, now) {
        if (!iso) {
            return "";
        }
        const seconds = Math.max(0, (now - Date.parse(iso)) / 1000);
        if (seconds < 60) {
            return qsTr("now");
        }
        if (seconds < 3600) {
            return qsTr("%1m").arg(Math.floor(seconds / 60));
        }
        if (seconds < 86400) {
            return qsTr("%1h").arg(Math.floor(seconds / 3600));
        }
        if (seconds < 86400 * 30) {
            return qsTr("%1d").arg(Math.floor(seconds / 86400));
        }
        return qsTr("%1mo").arg(Math.floor(seconds / (86400 * 30)));
    }

    Timer {
        id: ageRefreshTimer
        objectName: "ageRefreshTimer"

        interval: 60000
        repeat: true
        running: row.visible && !row.item.wakeLabel
        onTriggered: row.ageNow = Date.now()
    }

    onItemChanged: ageNow = Date.now()

    function requestSnooze(button) {
        const p = button.mapToItem(null, 0, button.height);
        row.snoozeRequested(p.x, p.y);
    }

    // Two lines and their padding (52 at the default type), or one control's height.
    implicitHeight: slim ? Theme.control.lg : Theme.space.sm * 2 + Theme.type.body.lineHeight + Theme.space.xxs + Theme.type.meta.lineHeight
    Accessible.role: Accessible.ListItem
    Accessible.name: item.title
    Accessible.description: [statusWord, projectName, branchName].filter(part => part.length > 0).join(", ")
    // The keyboard opens a row from the Sidebar's list (Enter at its cursor).
    Accessible.onPressAction: row.activated()
    // A pooled delegate (the list reuses them) is hidden but stays a child of
    // the list; without this a screen reader reads it with the live rows.
    Accessible.ignored: !row.visible

    Rectangle {
        id: rowBackground
        objectName: "rowBackground"
        anchors.fill: parent
        radius: Theme.radiusMd
        // Fade alpha without interpolating through black on light themes.
        readonly property color hoverColor: Theme.palette.color("sidebarRowHover", "#1c1c21")
        color: row.active || row.selected ? Theme.palette.color("sidebarRowActive", "#2a2a30") : Qt.alpha(hoverColor, hover.hovered ? hoverColor.a : 0)
        border.width: row.focused ? 1 : 0
        border.color: row.focusColor
    }

    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: Theme.space.sm
        anchors.bottomMargin: Theme.space.sm
        width: Theme.space.xxs
        radius: Theme.radiusPill
        color: row.indicatorColor
        visible: row.active && row.indicatorColor.a > 0
    }

    HoverHandler {
        id: hover
    }

    // Resting the pointer on a row previews the thread in a standard
    // tooltip: the status icon's word, the whole title, project, branch and
    // the latest activity. A hidden list (the phone's, under the thread a tap
    // opened) keeps its hover, so the row must be on screen too. The tip
    // stays in the row's column, under the row (over it when the window ends
    // first), so it covers the rows below for a moment and never the thread
    // beside the list. It is built only while the pointer rests here.
    readonly property ToolTip previewCard: previewLoader.item?.card ?? null

    Loader {
        id: previewLoader

        active: row.visible && hover.hovered && !slotHover.hovered && !row.draft && !!row.item.preview
        sourceComponent: Item {
            readonly property alias card: card

            ToolTip {
                id: card

                objectName: "rowPreview"
                parent: row
                x: 0
                y: row.height + Theme.space.xxs
                // Wraps rather than reach past the column; the window's edge
                // flips it over the row.
                width: Math.min(implicitWidth, row.width)
                visible: true
                delay: 600
                text: {
                    const preview = row.item.preview;
                    if (!preview) {
                        return "";
                    }
                    return [row.statusWord, row.oneLineTitle, preview.project, preview.branch, preview.activity].filter(line => !!line).join("\n");
                }
            }
            ShellToolTip {
                tip: card
            }
        }
    }

    DropArea {
        anchors.fill: parent
        enabled: !row.draft
        keys: ["text/uri-list"]
        onDropped: drop => {
            if (drop.hasUrls) {
                row.filesDropped(drop.urls);
                drop.accept(Qt.CopyAction);
            }
        }
    }

    TapHandler {
        acceptedButtons: Qt.LeftButton
        onTapped: {
            if (!row.draft && (point.modifiers & (Qt.ControlModifier | Qt.MetaModifier))) {
                row.selectionToggled();
            } else if (!row.draft && (point.modifiers & Qt.ShiftModifier)) {
                row.rangeSelected();
            } else {
                row.activated();
            }
        }
    }

    DragHandler {
        id: drag

        property bool cancelled: false

        target: null
        enabled: !row.draft && !row.offline
        acceptedDevices: row.touch ? PointerDevice.Mouse | PointerDevice.TouchPad : PointerDevice.AllDevices
        acceptedButtons: Qt.LeftButton
        onActiveChanged: {
            if (active) {
                cancelled = false;
            } else {
                row.dragEnded(!cancelled);
            }
        }
        onCanceled: cancelled = true
        onCentroidChanged: {
            if (active) {
                row.dragMoved(centroid.scenePosition.y);
            }
        }
    }

    // The menu opens on press, anywhere on the row. A
    // finger has no buttons to tell apart, so it would open the menu too.
    TapHandler {
        acceptedButtons: Qt.RightButton
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        gesturePolicy: TapHandler.WithinBounds
        onPressedChanged: {
            if (pressed) {
                row.menuRequested(point.scenePosition.x, point.scenePosition.y);
            }
        }
    }

    TapHandler {
        enabled: row.touch
        acceptedDevices: PointerDevice.TouchScreen
        onLongPressed: row.menuRequested(point.scenePosition.x, point.scenePosition.y)
    }

    // Row actions never take focus: the keyboard cursor stays on the list
    // and reaches them through the context menu.
    component RowAction: ShellButton {
        subtle: true
        focusPolicy: Qt.NoFocus
        implicitHeight: Theme.icon.lg
        implicitWidth: Theme.icon.lg
        iconSize: Theme.icon.sm
        iconTint: hovered ? row.textColor : row.secondaryColor
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.space.sm
        anchors.rightMargin: Theme.space.xs
        spacing: Theme.space.sm

        // The project's mark; the project's colour is here and nowhere else
        // on the row.
        ProjectIcon {
            objectName: "projectMark"
            // Centred on the title's line, one or two lines alike.
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: Math.round((row.height - lines.implicitHeight) / 2 + (Theme.type.body.lineHeight - size) / 2)
            Layout.preferredWidth: size
            Layout.preferredHeight: size
            // DIRECTION's 14px mark.
            size: Theme.icon.sm + Theme.space.xxs
            icon: row.projectIcon
            name: row.projectName
        }

        ColumnLayout {
            id: lines
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: Theme.space.xxs

            Text {
                objectName: "cardTitle"
                Layout.fillWidth: true
                text: row.oneLineTitle
                color: row.recedes ? row.secondaryColor : row.textColor
                font.pixelSize: Theme.type.body.size
                font.weight: Font.Medium
                lineHeight: Theme.type.body.lineHeight
                lineHeightMode: Text.FixedHeight
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                maximumLineCount: 1
            }

            // "project · branch": the project keeps at most half the line,
            // the branch takes the rest and loses its middle.
            Item {
                objectName: "rowDetail"
                Layout.fillWidth: true
                implicitHeight: Theme.type.meta.lineHeight
                visible: !row.slim && row.hasDetail

                Text {
                    id: projectText
                    objectName: "rowDetailProject"
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, row.branchName.length > 0 ? parent.width / 2 : parent.width)
                    visible: row.detailProject.length > 0
                    text: row.detailProject
                    color: row.projectColor
                    font.pixelSize: Theme.type.meta.size
                    elide: Text.ElideRight
                }

                Text {
                    id: detailSeparator
                    anchors.left: projectText.visible ? projectText.right : parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    visible: projectText.visible && row.branchName.length > 0
                    width: visible ? implicitWidth : 0
                    text: " · "
                    color: row.tertiaryColor
                    font.pixelSize: Theme.type.meta.size
                }

                Text {
                    objectName: "rowDetailBranch"
                    anchors.left: detailSeparator.right
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: row.branchName.length > 0
                    text: row.branchName
                    color: row.branchColor
                    font.pixelSize: Theme.type.meta.size
                    elide: Text.ElideMiddle
                }
            }
        }

        PluginMark {}

        // The status slot: one thing at a time. It holds DIRECTION's 44px
        // only while something occupies it (the actions, the jump key, a
        // status); a row at rest with just its age keeps 28px or the age's
        // width, whichever is less, and gives the title the rest.
        Item {
            objectName: "statusSlot"
            Layout.preferredWidth: row.slot === "age" ? Math.min(Math.ceil(ageText.implicitWidth), row.restingSlotWidth) : row.slotWidth
            Layout.fillHeight: true

            // Over the actions their own tooltips speak, not the preview.
            HoverHandler {
                id: slotHover
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.space.xs
                visible: row.slot === "actions"

                // Built only for pinned rows, so the hundreds of others pay nothing.
                Loader {
                    active: row.pinned && row.showActions
                    visible: active
                    sourceComponent: RowAction {
                        objectName: "unpinAction"
                        iconName: "pin-off"
                        Accessible.name: qsTr("Unpin thread")
                        onClicked: row.unpinRequested()
                    }
                }

                RowAction {
                    id: snoozeButton

                    visible: !row.pinned && row.canSnooze
                    iconName: "clock"
                    objectName: "snoozeAction"
                    Accessible.name: qsTr("Snooze")
                    onClicked: row.requestSnooze(snoozeButton)
                }

                RowAction {
                    visible: row.canSettle
                    iconName: "check"
                    objectName: "settleAction"
                    Accessible.name: qsTr("Settle")
                    onClicked: row.settleRequested()
                }

                RowAction {
                    visible: row.section === "snoozed"
                    iconName: "alarm-clock-off"
                    objectName: "wakeAction"
                    Accessible.name: qsTr("Wake")
                    toolTip: row.item.wakeDescription ? qsTr("Wakes %1").arg(row.item.wakeDescription) : ""
                    onClicked: row.unsnoozeRequested()
                }

                RowAction {
                    visible: row.section === "settled"
                    iconName: "undo-2"
                    objectName: "unsettleAction"
                    Accessible.name: qsTr("Un-settle")
                    onClicked: row.unsettleRequested()
                }
            }

            Rectangle {
                objectName: "jumpHint"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: row.slot === "jump"
                width: Math.min(parent.width, jumpText.implicitWidth + Theme.space.md)
                height: Theme.icon.lg
                radius: Theme.radiusPill
                color: Theme.palette.color("surfaceOverlay", "#18181b")
                border.width: 1
                border.color: Theme.palette.color("border", "#27272a")

                Text {
                    id: jumpText

                    anchors.centerIn: parent
                    text: row.jumpLabel
                    color: row.textColor
                    font.pixelSize: Theme.type.caption.size
                    font.weight: Font.Medium
                }
            }

            // A woke row's alarm acknowledges the wake when clicked.
            ShellButton {
                objectName: "wokeDismiss"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: row.slot === "status" && row.woke
                subtle: true
                focusPolicy: Qt.NoFocus
                implicitWidth: Theme.icon.lg
                implicitHeight: Theme.icon.lg
                iconName: "alarm-clock"
                iconSize: Theme.icon.sm
                iconTint: Theme.palette.color("warningForeground", "#f59e0b")
                toolTip: qsTr("Dismiss woke")
                Accessible.name: qsTr("Dismiss woke")
                onClicked: row.wokeDismissed()
            }

            ShellIcon {
                objectName: "statusIcon"
                anchors.right: parent.right
                anchors.rightMargin: (Theme.icon.lg - size) / 2
                anchors.verticalCenter: parent.verticalCenter
                visible: row.slot === "status" && !row.woke
                name: row.statusIcon
                size: Theme.icon.md
                color: row.statusColor
            }

            // Never elided: an age wider than the resting slot ("11mo")
            // reaches into the gap before the title instead.
            Text {
                id: ageText
                objectName: "rowAge"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: row.slot === "age"
                text: row.ageLabel
                color: row.tertiaryColor
                font.pixelSize: Theme.type.meta.size
            }
        }
    }

    // The mark of a thread an MC plugin started, while the plugin runs; made
    // only for such threads.
    component PluginMark: Loader {
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: visible ? item.implicitWidth : 0
        Layout.preferredHeight: visible ? item.implicitHeight : 0
        active: !!row.item.plugin
        // Whether the plugin drew a mark; not item.visible, which is false
        // while this Loader is hidden.
        visible: item !== null && item.item !== null
        sourceComponent: PluginThreadPart {
            objectName: "pluginRowMark"
            thread: row.item.plugin ? { id: row.item.threadId, title: row.item.title, environmentId: row.item.environmentId, plugin: row.item.plugin } : null
        }
    }
}
