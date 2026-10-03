pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import HalC2.Shell

// One thread (or draft) row of the Sidebar brick: a card for pinned and
// active threads (project, status or age, title, branch), a slim line for
// snoozed and settled ones. Hovering or focusing the row swaps the status
// slot for the section's actions (snooze and settle, wake, un-settle), the
// same ones the web app's sidebar shows on hover.
Item {
    id: row

    required property var item
    required property bool active
    property bool slim: false
    property string projectName: ""
    // Which sidebar group the row sits in: pinned, active, snoozed, settled
    // or draft. Decides the hover actions.
    property string section: "active"
    // Keyboard cursor: draws the focus ring and shows the actions.
    property bool focused: false
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
    signal wokeDismissed

    readonly property color textColor: Theme.palette.color("sidebarForeground", "#e4e4e7")
    readonly property color secondaryColor: Theme.palette.color("secondaryLabel", "#8b8b93")
    // Themes may colour the project and branch lines and mark the active
    // row with a bar; without those roles the row stays monochrome.
    readonly property color projectColor: Theme.palette.color("projectForeground", secondaryColor)
    readonly property color branchColor: Theme.palette.color("branchForeground", secondaryColor)
    readonly property color indicatorColor: Theme.palette.color("sidebarActiveIndicator", "transparent")
    readonly property color focusColor: Theme.palette.color("focus", "#3b82f6")
    readonly property bool draft: section === "draft"
    readonly property bool selected: item.selected === true
    readonly property bool woke: item.wokeAt !== null && item.wokeAt !== undefined
    readonly property bool parked: section === "snoozed" || section === "settled"
    // The thread's environment is unreachable: the row stays, says so, and
    // recedes until the environment comes back.
    readonly property bool offline: item.offline === true
    readonly property bool canSettle: !draft && !parked && item.canSettle === true
    readonly property bool canSnooze: !draft && !parked && item.canSnooze === true
    readonly property bool hasActions: !offline && (parked || canSettle || canSnooze)
    readonly property bool showActions: hasActions && (hover.hovered || focused)
    // The status word the web app's sidebar uses for each state; empty when the
    // row is at rest, then the slot shows the age (or the wake time).
    readonly property string statusWord: {
        if (row.offline) {
            return qsTr("Offline");
        }
        if (item.movingTo) {
            return qsTr("Moving");
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
            return "";
        }
        switch (item.status) {
        case "working":
            return "circle-dashed";
        case "limited":
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
        if (row.offline) {
            return row.secondaryColor;
        }
        switch (item.status) {
        case "approval":
            return Theme.palette.color("warning", "#f59e0b");
        case "input":
            return Theme.palette.color("accent", "#818cf8");
        case "working":
            return Theme.palette.color("info", "#38bdf8");
        case "waiting":
            return row.secondaryColor;
        case "limited":
            return Theme.palette.color("warning", "#f59e0b");
        case "failed":
            return Theme.palette.color("error", "#f87171");
        }
        if (row.woke) {
            return Theme.palette.color("warning", "#f59e0b");
        }
        if (item.unread === true) {
            return Theme.palette.color("success", "#34d399");
        }
        return row.secondaryColor;
    }
    readonly property bool showStatus: statusWord.length > 0
    // In-flight and read-ready rows recede: prominence is for rows that need
    // a human (done, failed, woke) and the one that is open.
    readonly property bool recedes: offline || !active && !woke && item.unread !== true && item.status !== "failed" && item.status !== "limited"
    // Titles keep the prompt's line breaks; the row shows them on one line,
    // as the web app does, so a multi-line title never overflows the card.
    readonly property string oneLineTitle: (item.title ?? "").replace(/\s+/g, " ").trim()
    readonly property string ageLabel: item.wakeLabel ? item.wakeLabel : relativeAge(item.updatedAt, ageNow)

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

    implicitHeight: slim ? 36 : 78
    Accessible.role: Accessible.ListItem
    Accessible.name: item.title

    Rectangle {
        id: rowBackground
        objectName: "rowBackground"
        anchors.fill: parent
        radius: 8
        // Fade alpha without interpolating through black on light themes.
        readonly property color hoverColor: Theme.palette.color("sidebarRowHover", "#1c1c21")
        color: row.active || row.selected ? Theme.palette.color("sidebarRowActive", "#2a2a30") : Qt.alpha(hoverColor, hover.hovered ? hoverColor.a : 0)
        border.width: row.focused ? 1 : 0
        border.color: row.focusColor

        Behavior on color {
            ColorAnimation {
                duration: 120
            }
        }
    }

    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: 8
        anchors.bottomMargin: 8
        width: 3
        radius: 1.5
        color: row.indicatorColor
        visible: row.active && row.indicatorColor.a > 0
    }

    HoverHandler {
        id: hover
    }

    // Resting the pointer on a row previews the thread.
    ToolTip.visible: hover.hovered && !row.draft && !row.showActions && !!row.item.preview
    ToolTip.delay: 700
    ToolTip.text: {
        const preview = row.item.preview;
        if (!preview) {
            return "";
        }
        return [row.oneLineTitle, preview.project, preview.branch, preview.activity].filter(line => !!line).join("\n");
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

    // The key that opens the row, while the jump modifier is held.
    Rectangle {
        objectName: "jumpHint"
        visible: !!row.item.jumpLabel
        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        z: 1
        implicitWidth: jumpText.implicitWidth + 12
        implicitHeight: 20
        radius: 10
        color: Theme.palette.color("surfaceOverlay", "#18181b")
        border.width: 1
        border.color: Theme.palette.color("border", "#27272a")

        Text {
            id: jumpText

            anchors.centerIn: parent
            text: row.item.jumpLabel ?? ""
            color: row.textColor
            font.pixelSize: 10
            font.weight: Font.Medium
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

    // The menu opens on press, anywhere on the row, like the web app's.
    TapHandler {
        acceptedButtons: Qt.RightButton
        gesturePolicy: TapHandler.WithinBounds
        onPressedChanged: {
            if (pressed) {
                row.menuRequested(point.scenePosition.x, point.scenePosition.y);
            }
        }
    }

    // Row actions never take focus: the keyboard cursor stays on the list
    // and reaches them through the context menu.
    component RowAction: ShellButton {
        subtle: true
        focusPolicy: Qt.NoFocus
        implicitHeight: 22
        implicitWidth: 22
        iconSize: 14
        iconTint: row.secondaryColor
    }

    // The right-hand slot: the section's actions while hovered or focused,
    // the woke pill (click acknowledges the wake), else the status or age.
    component StatusSlot: RowLayout {
        spacing: 2

        RowAction {
            id: snoozeButton

            visible: row.showActions && row.canSnooze
            iconName: "clock"
            objectName: "snoozeAction"
            Accessible.name: qsTr("Snooze")
            onClicked: row.requestSnooze(snoozeButton)
        }

        RowAction {
            visible: row.showActions && row.canSettle
            iconName: "check"
            objectName: "settleAction"
            Accessible.name: qsTr("Settle")
            onClicked: row.settleRequested()
        }

        RowAction {
            visible: row.showActions && row.section === "snoozed"
            iconName: "alarm-clock-off"
            objectName: "wakeAction"
            Accessible.name: qsTr("Wake")
            ToolTip.visible: hovered && !!row.item.wakeDescription
            ToolTip.text: qsTr("Wakes %1").arg(row.item.wakeDescription ?? "")
            onClicked: row.unsnoozeRequested()
        }

        RowAction {
            visible: row.showActions && row.section === "settled"
            iconName: "undo-2"
            objectName: "unsettleAction"
            Accessible.name: qsTr("Un-settle")
            onClicked: row.unsettleRequested()
        }

        ShellButton {
            visible: row.woke && !row.showActions
            subtle: true
            focusPolicy: Qt.NoFocus
            implicitHeight: 22
            leftPadding: 6
            rightPadding: 6
            iconName: "alarm-clock"
            iconSize: 12
            font.pixelSize: 12
            text: qsTr("Woke")
            tint: row.statusColor
            iconTint: row.statusColor
            objectName: "wokeDismiss"
            Accessible.name: qsTr("Dismiss woke")
            onClicked: row.wokeDismissed()
        }

        ShellIcon {
            visible: !row.showActions && !row.woke && row.showStatus && row.statusIcon.length > 0
            name: row.statusIcon
            size: 14
            color: row.statusColor
            Layout.alignment: Qt.AlignVCenter
        }

        Text {
            visible: !row.showActions && !row.woke
            text: row.showStatus ? row.statusWord : row.ageLabel
            color: row.showStatus ? row.statusColor : row.secondaryColor
            font.pixelSize: 12
            font.weight: Font.Medium
            font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Qt.application.font.family
        }
    }

    // Slim line: dimmed folder, title, status or age.
    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 8
        spacing: 10
        visible: row.slim

        ShellIcon {
            name: "folder"
            size: 16
            color: row.secondaryColor
            opacity: hover.hovered || row.focused ? 1 : 0.4
            Layout.alignment: Qt.AlignVCenter

            Behavior on opacity {
                NumberAnimation {
                    duration: 120
                }
            }
        }

        Text {
            Layout.fillWidth: true
            text: row.oneLineTitle
            color: Qt.alpha(row.secondaryColor, 0.7)
            font.pixelSize: 14
            font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Qt.application.font.family
            elide: Text.ElideRight
        }

        StatusSlot {
            Layout.alignment: Qt.AlignVCenter
        }
    }

    // Card: project line, title, branch.
    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 8
        anchors.topMargin: 8
        anchors.bottomMargin: 8
        spacing: 0
        visible: !row.slim

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 22
            spacing: 6

            ShellIcon {
                name: "folder"
                size: 16
                color: row.projectColor
                Layout.alignment: Qt.AlignVCenter
            }

            Text {
                Layout.fillWidth: true
                text: row.projectName
                color: row.projectColor
                font.pixelSize: 12
                font.weight: Font.Medium
                font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Qt.application.font.family
                elide: Text.ElideRight
            }

            StatusSlot {
                Layout.alignment: Qt.AlignVCenter
            }
        }

        Text {
            Layout.fillWidth: true
            Layout.topMargin: 2
            objectName: "cardTitle"
            text: row.oneLineTitle
            color: row.recedes ? Qt.alpha(row.textColor, 0.72) : row.textColor
            font.pixelSize: 14
            font.weight: Font.Medium
            font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Qt.application.font.family
            elide: Text.ElideRight
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 2
            spacing: 6

            ShellIcon {
                visible: row.item.branch !== null && row.item.branch !== undefined
                name: "git-branch"
                size: 12
                color: row.branchColor
                Layout.alignment: Qt.AlignVCenter
            }

            Text {
                Layout.fillWidth: true
                text: row.item.branch ?? ""
                color: row.branchColor
                font.pixelSize: 12
                font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Qt.application.font.family
                elide: Text.ElideRight
            }
        }
    }
}
