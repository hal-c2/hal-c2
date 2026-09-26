import OpenTUI

// One thread in the list: status dot, title, and the row's trailing fact (a
// snooze wake time, the status label, or the age). `item` is a
// `Shell.state.sidebar` thread (ShellSidebarThread plus glyph, age, project).
//
// Click opens the thread; right-click or a half-second press opens its
// context menu (`thread.menu`) where the pointer is.
Item {
    id: row
    property var item: null
    property bool active: false
    // Which group the row sits in: active, snoozed or settled.
    property string section: "active"
    // Where a left press started, for the long-press menu.
    property var pressAt: null

    readonly property string trailing: item
        ? (item.wakeLabel ?? item.statusLabel ?? item.age)
        : ""

    flexDirection: "row"
    height: 1

    onMouseDown: (mouse) => {
        if (!row.item) return
        mouse.accepted = true
        if (mouse.button === 2) {
            longPress.stop()
            Shell.dispatch("thread.menu", { key: row.item.key, x: mouse.screenX, y: mouse.screenY })
            return
        }
        if (mouse.button !== 0) return
        row.pressAt = { x: mouse.screenX, y: mouse.screenY }
        longPress.restart()
    }
    onMouseUp: (mouse) => {
        if (!row.item || mouse.button !== 0) return
        mouse.accepted = true
        // A press that already opened the menu does not also open the thread.
        if (row.pressAt === null) return
        row.pressAt = null
        longPress.stop()
        Shell.dispatch("thread.open", { key: row.item.key })
    }
    onMouseDrag: (mouse) => {
        if (row.pressAt === null) return
        if (Math.abs(mouse.screenX - row.pressAt.x) + Math.abs(mouse.screenY - row.pressAt.y) > 1) {
            longPress.stop()
            row.pressAt = null
        }
    }

    Timer {
        id: longPress
        interval: 500
        onTriggered: {
            if (!row.item || row.pressAt === null) return
            const at = row.pressAt
            row.pressAt = null
            Shell.dispatch("thread.menu", { key: row.item.key, x: at.x, y: at.y })
        }
    }

    Text {
        text: row.active ? "▌" : " "
        color: Theme.colors.accent
    }
    Text {
        text: row.item ? row.item.glyph + " " : ""
        color: row.item ? Theme.ansi(row.item.glyphColor) : Theme.colors.faint
    }
    Text {
        flexGrow: 1
        flexShrink: 1
        wrapMode: "none"
        truncate: true
        text: row.item ? row.item.title : ""
        color: row.active ? Theme.colors.accent : Theme.colors.text
        font.bold: row.active
    }
    Text {
        flexShrink: 0
        text: " " + row.trailing
        color: row.item && row.item.statusLabel !== null && row.item.wakeLabel === null
            ? Theme.ansi(row.item.glyphColor)
            : Theme.colors.faint
    }
}
