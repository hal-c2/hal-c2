import OpenTUI

// One line of the thread list, as the host drew it (`Shell.state.sidebar.lines`).
// An active thread's card is three padded lines, on the selection background
// when selected, and a gap line.
//
// On a thread, click opens it; right-click or a half-second press opens its
// context menu (`thread.menu`) where the pointer is. A shelf header toggles
// its shelf and "Show more" loads the rest.
Rectangle {
    id: row
    property var line: null
    // Where a left press on a thread started, for the long-press menu.
    property var pressAt: null

    readonly property bool isThread: line !== null && line.kind === "thread"

    height: 1
    flexShrink: 0
    paddingX: line !== null && line.card ? 1 : 0
    color: line !== null && line.highlight ? Theme.colors.selectedBg : Theme.colors.bg

    onMouseDown: (mouse) => {
        if (row.line === null) return
        if (row.line.kind === "section") {
            Shell.dispatch("sidebar.section.toggle", { section: row.line.section })
            return
        }
        if (row.line.kind === "more") {
            Shell.dispatch("sidebar.more")
            return
        }
        if (!row.isThread) return
        mouse.accepted = true
        if (mouse.button === 2) {
            longPress.stop()
            Shell.dispatch("thread.menu", { key: row.line.key, x: mouse.screenX, y: mouse.screenY })
            return
        }
        if (mouse.button !== 0) return
        row.pressAt = { x: mouse.screenX, y: mouse.screenY }
        longPress.restart()
    }
    onMouseUp: (mouse) => {
        if (!row.isThread || mouse.button !== 0) return
        mouse.accepted = true
        // A press that already opened the menu does not also open the thread.
        if (row.pressAt === null) return
        row.pressAt = null
        longPress.stop()
        Shell.dispatch("thread.open", { key: row.line.key })
    }
    onMouseDrag: (mouse) => {
        if (row.pressAt === null) return
        if (Math.abs(mouse.screenX - row.pressAt.x) + Math.abs(mouse.screenY - row.pressAt.y) > 1) {
            longPress.stop()
            row.pressAt = null
        }
    }
    onMouseOut: (mouse) => {
        longPress.stop()
        row.pressAt = null
    }

    Timer {
        id: longPress
        interval: 500
        onTriggered: {
            if (!row.isThread || row.pressAt === null) return
            const at = row.pressAt
            row.pressAt = null
            Shell.dispatch("thread.menu", { key: row.line.key, x: at.x, y: at.y })
        }
    }

    Text {
        flexGrow: 1
        wrapMode: "none"
        text: row.line !== null ? row.line.text : ""
    }
}
