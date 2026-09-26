import OpenTUI

// Pending approvals (Shell.state.approvals): the selected one answers to ^A
// (approve) and ^R (deny); ↑/↓ pick another while the prompt is empty.
Rectangle {
    id: panel
    objectName: "approvals"
    readonly property var approvals: Shell.state.approvals
    readonly property bool promptEmpty: Shell.state.composer ? Shell.state.composer.text === "" : true
    readonly property bool keysLive: Shell.state.mode === "compose" && approvals.count > 0

    visible: approvals.count > 0
    flexDirection: "column"
    flexShrink: 0
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
        delegate: Text {
            objectName: "approval-" + modelData.requestId
            text: (modelData.active ? "▸ " : "  ") + modelData.label
            color: modelData.active ? Theme.colors.text : Theme.colors.dim
        }
    }
    Text { text: panel.approvals.hint; color: Theme.colors.dim }

    Shortcut {
        sequence: "ctrl+a"
        enabled: panel.keysLive
        onActivated: Shell.dispatch("approval.approve")
    }
    Shortcut {
        sequence: "ctrl+r"
        enabled: panel.keysLive
        onActivated: Shell.dispatch("approval.decline")
    }
    Shortcut {
        sequence: "up"
        enabled: panel.keysLive && panel.approvals.count > 1 && panel.promptEmpty
        onActivated: Shell.dispatch("approval.previous")
    }
    Shortcut {
        sequence: "down"
        enabled: panel.keysLive && panel.approvals.count > 1 && panel.promptEmpty
        onActivated: Shell.dispatch("approval.next")
    }
}
