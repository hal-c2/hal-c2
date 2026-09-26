import OpenTUI

// Alerts for threads the user is not looking at (Shell.state.notifications),
// newest first. Clicking the title opens the thread; × dismisses.
Item {
    id: stack
    objectName: "notifications"
    readonly property var items: Shell.state.notifications ? Shell.state.notifications.items : []

    visible: items.length > 0
    flexDirection: "column"
    flexShrink: 0

    Repeater {
        model: stack.items
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
}
