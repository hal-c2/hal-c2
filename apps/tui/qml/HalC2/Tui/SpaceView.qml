import OpenTUI

// The Spaces and their pages (`Shell.state.space`), in the conversation pane's
// place: the Spaces, one Space's page tree and its trash, or one page's blocks
// with their comments. The host keeps the streams, the selection, the window of
// rows that fits and each row's styled line; this paints them.
Rectangle {
    id: view
    objectName: "spaceView"
    readonly property var space: Shell.state.space

    flexDirection: "column"
    flexGrow: 1
    flexShrink: 1
    border.width: 1
    border.style: "rounded"
    border.color: Theme.colors.accent
    color: Theme.colors.bg
    paddingX: 1

    Text {
        objectName: "spaceHeader"
        flexShrink: 0
        wrapMode: "none"
        truncate: true
        text: view.space.title
        color: Theme.colors.accent
        Span { text: view.space.hint; color: Theme.colors.dim }
    }

    Text {
        objectName: "spaceMessage"
        visible: view.space.message !== ""
        text: view.space.message
        color: view.space.status === "error" ? Theme.colors.error : Theme.colors.dim
    }

    Repeater {
        model: view.space.rows
        delegate: Rectangle {
            flexShrink: 0
            height: 1
            color: modelData.selected ? Theme.colors.selectedBg : Theme.colors.bg
            onMouseDown: Shell.dispatch("space.select", { key: modelData.key })
            Text {
                wrapMode: "none"
                truncate: true
                text: modelData.line
            }
        }
    }
}
