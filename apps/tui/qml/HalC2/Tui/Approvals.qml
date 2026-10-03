import OpenTUI

// Pending approvals (Shell.state.approvals), under the timeline at its width.
// The selected one says what kind of permission it wants and answers to the
// chords its options name (^A approve, ^S always, ^R decline, ^X cancel);
// ↑/↓ pick another while the prompt is empty. A request whose provider is gone
// shows why it cannot be answered instead.
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
            objectName: "approvalCount"
            visible: panel.approvals.countText !== ""
            text: "  " + panel.approvals.countText
            color: Theme.colors.dim
        }
    }
    Text {
        objectName: "approvalTitle"
        text: panel.approvals.title
        color: Theme.colors.text
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
    Repeater {
        model: panel.approvals.warnings
        delegate: Text {
            objectName: "approvalWarning-" + modelData.decision
            wrapMode: "word"
            text: modelData.text
            color: Theme.colors.warning
        }
    }
    Text {
        objectName: "approvalHint"
        visible: panel.approvals.canRespond
        wrapMode: "word"
        text: panel.approvals.hint
        color: Theme.colors.dim
    }
    Text {
        objectName: "approvalProblem"
        visible: !panel.approvals.canRespond
        wrapMode: "word"
        text: panel.approvals.problem
        color: Theme.colors.error
    }
}
