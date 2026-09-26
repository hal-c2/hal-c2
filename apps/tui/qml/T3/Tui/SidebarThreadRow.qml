import OpenTUI

// One thread in the list: status dot, title, age. `item` is a
// `Shell.state.sidebar` thread (ShellSidebarThread plus glyph, age, project).
Item {
    id: row
    property var item: null
    property bool active: false
    // Which group the row sits in: active, snoozed or settled.
    property string section: "active"

    flexDirection: "row"
    height: 1

    Text {
        text: row.item ? row.item.glyph + " " : ""
        color: row.item ? Theme.ansi(row.item.glyphColor) : Theme.colors.faint
    }
    Text {
        flexGrow: 1
        flexShrink: 1
        text: row.item ? row.item.title : ""
        color: row.active ? Theme.colors.accent : Theme.colors.text
        font.bold: row.active
    }
    Text {
        text: row.item ? " " + (row.item.wakeLabel ?? row.item.age) : ""
        color: Theme.colors.faint
    }
}
