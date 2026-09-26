import OpenTUI

// One pre-styled timeline line (a `Shell.state.timeline` item line): its text,
// an optional right-aligned part, and the action a click dispatches. A line
// with an `image` draws that attachment preview inline (Kitty graphics, only
// when the host's `graphics.inlineImages` let it load) instead of text.
//
// Clicks act through `Qt.callLater`: one click that reaches the line more than
// once (nested handlers, a repeated report) coalesces into a single dispatch
// that runs after the mouse event has been handled.
Item {
    id: row
    property var line: null
    readonly property var right: line ? line.right : null
    readonly property var image: line ? line.image : null

    flexDirection: "row"
    flexShrink: 0

    function activate(action, payload) {
        Shell.dispatch(action, payload)
    }

    function click(part) {
        if (part && part.action) Qt.callLater(row.activate, part.action, part.payload)
    }

    Text {
        visible: row.image === null
        flexGrow: 1
        flexShrink: 1
        wrapMode: "word"
        text: row.line ? row.line.text : ""
        onMouseDown: row.click(row.line)
    }
    Image {
        objectName: row.image ? "attachmentImage-" + row.image.id : ""
        visible: row.image !== null
        width: row.image ? row.image.columns : 0
        height: row.image ? row.image.rows : 0
        flexShrink: 0
        fit: "fill"
        protocol: "kitty"
        source: row.image ? row.image.source : null
        onMouseDown: row.click(row.line)
    }
    Text {
        visible: row.right !== null && row.right.action !== ""
        text: row.right ? row.right.text : ""
        onMouseDown: row.click(row.right)
    }
}
