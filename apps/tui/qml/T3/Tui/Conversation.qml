import OpenTUI

// The main column's conversation. A placeholder until the timeline and
// composer bricks land: the selected thread's title, or an empty state.
Rectangle {
    id: conversation
    objectName: "conversation"
    readonly property var page: Shell.state.page

    color: Theme.colors.bg
    flexDirection: "column"
    paddingX: 1

    Text {
        objectName: "conversationTitle"
        text: conversation.page.kind === "thread" ? conversation.page.title : "No thread selected"
        color: conversation.page.kind === "thread" ? Theme.colors.text : Theme.colors.faint
        font.bold: conversation.page.kind === "thread"
    }
    Text {
        visible: conversation.page.kind === "thread" && conversation.page.projectTitle !== null
        text: conversation.page.kind === "thread" ? (conversation.page.projectTitle ?? "") : ""
        color: Theme.colors.dim
    }
}
