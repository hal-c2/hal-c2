import OpenTUI

// The main column's conversation: header, timeline (or the diff viewer), and
// what the thread needs from the user above the prompt: approvals, the
// agent's question, the revert picker and the thread's key hints.
Rectangle {
    id: conversation
    objectName: "conversation"
    readonly property var page: Shell.state.page
    readonly property var timeline: Shell.state.timeline
    readonly property var header: timeline.header

    color: Theme.colors.bg
    flexDirection: "column"
    paddingX: 1

    Item {
        flexDirection: "row"
        flexShrink: 0
        Text {
            objectName: "conversationTitle"
            flexGrow: 1
            flexShrink: 1
            text: conversation.header ? conversation.header.text : "No thread selected"
            color: conversation.header ? Theme.colors.text : Theme.colors.faint
        }
        Text {
            objectName: "conversationStatus"
            visible: conversation.header !== null
            text: conversation.header ? conversation.header.right.text : ""
        }
    }
    Text {
        objectName: "contextWindow"
        visible: conversation.timeline.context !== null
        text: conversation.timeline.context ?? ""
    }
    Notifications {}

    Timeline { visible: !Shell.state.diff.open }
    DiffViewer {}

    Approvals {}
    PendingUserInput {}
    RevertPicker {}
    ThreadHints {}

    Shortcut {
        sequence: "ctrl+y"
        enabled: Shell.state.mode === "compose" && conversation.timeline.plan !== null
        onActivated: Shell.dispatch("plan.implement")
    }
    Shortcut {
        sequence: "ctrl+u"
        enabled: Shell.state.mode === "compose" && Shell.state.userInput.deferred
        onActivated: Shell.dispatch("userInput.reopen")
    }
}
