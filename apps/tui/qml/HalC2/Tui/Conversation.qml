import OpenTUI

// The main column's conversation. Like MessagesTimeline, the thread sits in a
// rounded faint pane: the header, the context meter, the timeline and the
// pending approvals. Like ChatView, the file browser, the diff viewer and the
// image preview take the pane's place while open, in that order; the revert
// picker follows. A new-thread draft shows the pane empty (the composer below
// holds the draft).
Rectangle {
    id: conversation
    objectName: "conversation"
    readonly property var page: Shell.state.page
    readonly property var timeline: Shell.state.timeline
    readonly property var header: draft ? null : timeline.header
    readonly property bool draft: page.kind === "draft"
    readonly property bool filesOpen: Shell.state.files.open
    readonly property bool diffOpen: !filesOpen && Shell.state.diff.open
    readonly property bool imageOpen: !filesOpen && !diffOpen && Shell.state.imageViewer !== null

    color: Theme.colors.bg
    flexDirection: "column"

    Notifications {}

    Rectangle {
        objectName: "conversationPane"
        visible: !conversation.filesOpen && !conversation.diffOpen && !conversation.imageOpen
        flexDirection: "column"
        flexGrow: 1
        flexShrink: 1
        border.width: 1
        border.style: "rounded"
        border.color: Theme.colors.faint
        paddingX: 1

        Text {
            objectName: "conversationEmpty"
            visible: conversation.timeline.kind === "none" && !conversation.draft
            text: conversation.timeline.emptyHint
            color: Theme.colors.dim
        }
        Item {
            visible: conversation.header !== null
            flexDirection: "row"
            flexShrink: 0
            Text {
                objectName: "conversationTitle"
                flexGrow: 1
                flexShrink: 1
                text: conversation.header ? conversation.header.text : ""
            }
            Text {
                objectName: "conversationStatus"
                text: conversation.header ? conversation.header.right.text : ""
            }
        }
        Text {
            objectName: "contextWindow"
            visible: conversation.timeline.context !== null && !conversation.draft
            text: conversation.timeline.context ?? ""
        }
        Timeline { visible: conversation.timeline.kind !== "none" && !conversation.draft }
        Approvals { visible: !conversation.draft && Shell.state.approvals.count > 0 }
    }
    FilesPanel {}
    FileViewer {}
    DiffViewer { visible: conversation.diffOpen; flexShrink: 1 }
    ImageViewer { visible: conversation.imageOpen }

    RevertPicker {}
}
