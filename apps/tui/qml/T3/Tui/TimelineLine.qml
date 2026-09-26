import OpenTUI

// One pre-styled timeline line (a `Shell.state.timeline` item line): its text,
// an optional right-aligned part, and the action a click dispatches.
Item {
    id: row
    property var line: null
    readonly property var right: line ? line.right : null

    flexDirection: "row"
    flexShrink: 0

    Text {
        flexGrow: 1
        flexShrink: 1
        wrapMode: "word"
        text: row.line ? row.line.text : ""
        onMouseDown: if (row.line && row.line.action) Shell.dispatch(row.line.action, row.line.payload)
    }
    Text {
        visible: row.right !== null && row.right.action !== ""
        text: row.right ? row.right.text : ""
        onMouseDown: if (row.right && row.right.action) Shell.dispatch(row.right.action, row.right.payload)
    }
}
