import OpenTUI

// Alerts for threads the user is not looking at (Shell.state.notifications),
// newest first. [Open] opens the thread; × dismisses. Only the newest few
// rows show; the rest are one click (or the "Notifications…" command) away.
Item {
    id: stack
    objectName: "notifications"
    readonly property var items: Shell.state.notifications ? Shell.state.notifications.items : []
    readonly property int shown: 3

    visible: items.length > 0
    flexDirection: "column"
    flexShrink: 0

    Repeater {
        model: stack.items.slice(0, stack.shown)
        delegate: Item {
            id: card
            readonly property var note: modelData
            objectName: "notification-" + note.id
            flexDirection: "row"
            height: 1
            Text {
                text: card.note.type === "error" ? "✗ " : card.note.type === "success" ? "✓ " : "⚠ "
                color: card.note.type === "error"
                    ? Theme.colors.error
                    : card.note.type === "success" ? Theme.colors.success : Theme.colors.warning
            }
            Text {
                flexGrow: 1
                flexShrink: 1
                text: card.note.title + (card.note.description ? " · " + card.note.description : "")
                color: Theme.colors.text
            }
            Repeater {
                model: card.note.actions
                delegate: Text {
                    objectName: "notificationAction-" + card.note.id + "-" + modelData.id
                    text: " [" + modelData.label + "]"
                    color: Theme.colors.accent
                    onMouseDown: Shell.dispatch("notification.action", { id: card.note.id, actionId: modelData.id })
                }
            }
            Text {
                objectName: "notificationDismiss-" + card.note.id
                text: " ×"
                color: Theme.colors.dim
                onMouseDown: Shell.dispatch("notification.dismiss", { id: card.note.id })
            }
        }
    }

    Text {
        objectName: "notificationsMore"
        visible: stack.items.length > stack.shown
        text: "+" + (stack.items.length - stack.shown) + (stack.items.length - stack.shown === 1 ? " more alert" : " more alerts")
        color: Theme.colors.accent
        onMouseDown: Shell.dispatch("reach.notifications", {})
    }
}
