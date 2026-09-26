import OpenTUI

// Pending approvals (Shell.state.approvals), under the timeline at its width:
// the selected one answers to ^A (approve) and ^R (deny); ↑/↓ pick another
// while the prompt is empty.
Rectangle {
    id: panel
    objectName: "approvals"
    readonly property var approvals: Shell.state.approvals

    visible: approvals.count > 0
    flexDirection: "column"
    flexShrink: 0
    width: Shell.state.timeline.width
    alignSelf: "center"
    border.width: 1
    border.style: "rounded"
    border.color: Theme.colors.error
    paddingX: 1

    Item {
        flexDirection: "row"
        Text { text: "Approval required"; color: Theme.colors.error }
        Text {
            visible: panel.approvals.countText !== ""
            text: "  " + panel.approvals.countText
            color: Theme.colors.dim
        }
    }
    Repeater {
        model: panel.approvals.items
        delegate: Item {
            objectName: "approval-" + modelData.requestId
            flexDirection: "row"
            Text {
                text: modelData.active ? "▸ " : "  "
                color: modelData.active ? Theme.colors.accent : Theme.colors.dim
            }
            Text {
                text: modelData.label
                color: modelData.active ? Theme.colors.text : Theme.colors.dim
            }
        }
    }
    Text { text: panel.approvals.hint; color: Theme.colors.dim }
}
