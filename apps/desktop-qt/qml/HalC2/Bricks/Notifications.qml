pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Toasts, newest first (Shell.state.toasts, NativeShell's ToastController),
// as the web app's stack: the newest in front, two more peeking out behind it,
// the rest kept but hidden until the stack is expanded. The pointer over the
// stack expands it; on a touch screen a tap does, and a tap outside it or on it
// again collapses it. Expanding holds every toast's time (the controller's).
// Place it over the window; dismiss and action clicks go back by id.
Item {
    id: host

    readonly property var items: Shell.state.toasts ? Shell.state.toasts.items : []
    readonly property bool expanded: !!(Shell.state.toasts && Shell.state.toasts.expanded)
    property int cardWidth: 340
    // Cards that lie over a screen's whole content (a phone's): the surface is
    // laid on the canvas, so what is under a card does not show through one the
    // Theme has thinned (Appearance's glass).
    property bool opaque: false
    // Anchored by its bottom edge: the newest sits at the bottom and the stack
    // peeks and expands upwards (the web's bottom positions).
    property bool fromBottom: false
    // Taller than this when expanded, the stack scrolls.
    property real maximumHeight: Infinity

    // Cards shown when collapsed, as Base UI's default limit; the rest wait.
    readonly property int shownCollapsed: 3
    readonly property int gap: 12
    readonly property int peek: 12
    // Each card's own height, newest first; measure() keeps it.
    property var heights: []
    // The toasts by id, changed in place: a card rereads its own when its
    // `revision` moves, so a publish leaves the other cards as they are.
    readonly property var byId: ({})
    property bool pinned: false
    readonly property real frontHeight: heights.length > 0 ? heights[0] : 0
    readonly property var offsets: {
        const list = [];
        let at = 0;
        for (const height of heights) {
            list.push(at);
            at += height + gap;
        }
        return list;
    }
    readonly property real stackHeight: {
        if (heights.length === 0)
            return 0;
        if (expanded)
            return offsets[offsets.length - 1] + heights[heights.length - 1];
        return frontHeight + Math.min(heights.length - 1, shownCollapsed - 1) * peek;
    }
    readonly property bool wantsExpanded: hover.hovered || pinned

    implicitWidth: cardWidth
    implicitHeight: Math.min(stackHeight, maximumHeight)
    visible: items.length > 0

    onItemsChanged: sync()
    Component.onCompleted: sync()
    onWantsExpandedChanged: {
        if (wantsExpanded !== expanded)
            Shell.dispatch("notification.expand", {
                expanded: wantsExpanded
            });
    }
    onExpandedChanged: {
        if (!expanded)
            pinned = false;
        Qt.callLater(scrollToFront);
    }

    // Keeps `cards` in the controller's order without remaking the cards that
    // stay, so only a new toast animates in.
    function sync() {
        const shown = new Set(items.map(item => item.id));
        for (let i = cards.count - 1; i >= 0; --i) {
            const id = cards.get(i).toastId;
            if (shown.has(id))
                continue;
            cards.remove(i);
            delete byId[id];
        }
        for (let i = 0; i < items.length; ++i) {
            const item = items[i];
            const changed = byId[item.id] !== undefined && JSON.stringify(byId[item.id]) !== JSON.stringify(item);
            byId[item.id] = item;
            if (i < cards.count && cards.get(i).toastId === item.id) {
                if (changed)
                    cards.setProperty(i, "revision", cards.get(i).revision + 1);
                continue;
            }
            let at = -1;
            for (let j = i + 1; j < cards.count && at < 0; ++j) {
                if (cards.get(j).toastId === item.id)
                    at = j;
            }
            if (at >= 0) {
                cards.move(at, i, 1);
                if (changed)
                    cards.setProperty(i, "revision", cards.get(i).revision + 1);
            } else {
                cards.insert(i, {
                    toastId: item.id,
                    revision: 0
                });
            }
        }
        if (items.length === 0)
            pinned = false;
        Qt.callLater(measure);
    }

    function measure() {
        const list = [];
        for (let i = 0; i < repeater.count; ++i) {
            const card = repeater.itemAt(i);
            if (card)
                list.push(card.naturalHeight);
        }
        if (JSON.stringify(list) !== JSON.stringify(heights))
            heights = list;
    }

    function scrollToFront() {
        flick.contentY = fromBottom ? Math.max(0, flick.contentHeight - flick.height) : 0;
    }

    // Whether (x, y) in the host is on a button of a card, which acts rather
    // than toggles the stack.
    function onButton(x, y) {
        let item = flick.contentItem;
        let point = host.mapToItem(item, x, y);
        for (;;) {
            const child = item.childAt(point.x, point.y);
            if (!child)
                return false;
            if (child instanceof AbstractButton)
                return true;
            point = item.mapToItem(child, point.x, point.y);
            item = child;
        }
    }

    function typeColor(type) {
        switch (type) {
        case "error":
            return Theme.palette.color("error", "#ef4444");
        case "warning":
            return Theme.palette.color("warning", "#e0af68");
        case "success":
            return Theme.palette.color("update", "#22c55e");
        case "loading":
            return Theme.palette.color("textMuted", "#8b8b93");
        default:
            return Theme.palette.color("accent", "#3b82f6");
        }
    }

    ListModel {
        id: cards
    }

    HoverHandler {
        id: hover
    }

    TapHandler {
        acceptedDevices: PointerDevice.TouchScreen
        onTapped: eventPoint => {
            if (!host.onButton(eventPoint.position.x, eventPoint.position.y))
                host.pinned = !host.expanded;
        }
    }

    // A touch anywhere else in the window collapses a tapped-open stack; it
    // only watches, so the touch still reaches what it landed on.
    PointHandler {
        parent: host.Window.contentItem
        enabled: host.pinned
        acceptedDevices: PointerDevice.TouchScreen
        onActiveChanged: {
            if (!active)
                return;
            const at = host.mapFromItem(null, point.scenePosition.x, point.scenePosition.y);
            if (!host.contains(at))
                host.pinned = false;
        }
    }

    Flickable {
        id: flick

        anchors.fill: parent
        contentWidth: width
        contentHeight: host.stackHeight
        interactive: contentHeight > height
        clip: interactive
        boundsBehavior: Flickable.StopAtBounds
        onHeightChanged: host.scrollToFront()
        onContentHeightChanged: host.scrollToFront()

        Repeater {
            id: repeater

            model: cards
            onItemAdded: Qt.callLater(host.measure)
            onItemRemoved: Qt.callLater(host.measure)

            delegate: Rectangle {
                id: card

                required property int index
                required property string toastId
                required property int revision
                readonly property var toast: {
                    card.revision;
                    return host.byId[card.toastId] ?? null;
                }
                readonly property real naturalHeight: body.implicitHeight + 28
                readonly property bool behind: index > 0 && !host.expanded
                readonly property bool hidden: behind && index >= host.shownCollapsed
                // From the stack's anchored edge to the card's: the collapsed
                // stack scales each card behind down a tenth more and shows its
                // far edge a peek past the one before it.
                readonly property real shrunk: behind ? Math.max(0, 1 - index * 0.1) : 1
                readonly property real edge: host.expanded ? (host.offsets[index] ?? 0) : index * host.peek + (1 - shrunk) * host.frontHeight
                property bool entered: false

                objectName: "notification-" + toastId
                anchors.top: host.fromBottom ? undefined : parent.top
                anchors.bottom: host.fromBottom ? parent.bottom : undefined
                anchors.topMargin: edge
                anchors.bottomMargin: edge
                width: host.cardWidth
                height: behind ? host.frontHeight : naturalHeight
                z: -index
                scale: shrunk
                transformOrigin: host.fromBottom ? Item.Bottom : Item.Top
                opacity: hidden || !entered ? 0 : 1
                visible: opacity > 0
                enabled: !behind
                radius: Theme.radius
                color: host.opaque ? Qt.tint(Theme.palette.color("canvas", "#0b0b0d"), Theme.palette.color("surfaceOverlay", "#18181b")) : Theme.palette.color("surfaceOverlay", "#18181b")
                border.color: Theme.palette.color("border", "#27272a")
                border.width: 1
                // Slides in from the edge, like the web app's toasts.
                transform: Translate {
                    x: card.entered ? 0 : 24

                    Behavior on x {
                        NumberAnimation {
                            duration: 220
                            easing.type: Easing.OutCubic
                        }
                    }
                }
                onNaturalHeightChanged: Qt.callLater(host.measure)
                Component.onCompleted: entered = true

                Behavior on anchors.topMargin {
                    NumberAnimation {
                        duration: 250
                        easing.type: Easing.OutCubic
                    }
                }

                Behavior on anchors.bottomMargin {
                    NumberAnimation {
                        duration: 250
                        easing.type: Easing.OutCubic
                    }
                }

                Behavior on scale {
                    NumberAnimation {
                        duration: 250
                        easing.type: Easing.OutCubic
                    }
                }

                Behavior on opacity {
                    NumberAnimation {
                        duration: 180
                    }
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.margins: 1
                    anchors.topMargin: Math.max(card.border.width, Math.min(card.radius, card.height / 2))
                    anchors.bottomMargin: anchors.topMargin
                    width: 3
                    radius: 2
                    color: host.typeColor(card.toast ? card.toast.type : "")
                }

                ColumnLayout {
                    id: body

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 14
                    anchors.leftMargin: 18
                    spacing: 6
                    // Behind the front card only its edge shows.
                    opacity: card.behind ? 0 : 1

                    Behavior on opacity {
                        NumberAnimation {
                            duration: 180
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10

                        Text {
                            Layout.fillWidth: true
                            text: card.toast ? card.toast.title : ""
                            color: Theme.palette.color("text", "#e4e4e7")
                            font.pixelSize: Math.round(13 * Theme.fontScale)
                            font.bold: true
                            font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
                            wrapMode: Text.Wrap
                        }

                        ShellButton {
                            Layout.alignment: Qt.AlignTop
                            Layout.topMargin: -4
                            Layout.rightMargin: -6
                            subtle: true
                            implicitWidth: 26
                            implicitHeight: 26
                            leftPadding: 0
                            rightPadding: 0
                            text: "✕"
                            tint: Theme.palette.color("textMuted", "#8b8b93")
                            font.pixelSize: Math.round(11 * Theme.fontScale)
                            objectName: "notificationDismiss-" + card.toastId
                            Accessible.name: qsTr("Dismiss")
                            onClicked: Shell.dispatch("notification.dismiss", {
                                id: card.toastId
                            })
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: !!card.toast && (card.toast.description ?? "").length > 0
                        text: card.toast ? card.toast.description ?? "" : ""
                        color: Theme.palette.color("textMuted", "#8b8b93")
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
                        lineHeight: 1.2
                        wrapMode: Text.Wrap
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: 4
                        visible: !!card.toast && card.toast.actions.length > 0
                        spacing: 8

                        Item {
                            Layout.fillWidth: true
                        }

                        Repeater {
                            model: card.toast ? card.toast.actions : []

                            delegate: ShellButton {
                                required property var modelData

                                objectName: "notificationAction-" + card.toastId + "-" + modelData.id
                                primary: modelData.primary
                                text: modelData.label
                                onClicked: Shell.dispatch("notification.action", {
                                    id: card.toastId,
                                    actionId: modelData.id
                                })
                            }
                        }
                    }
                }
            }
        }
    }
}
