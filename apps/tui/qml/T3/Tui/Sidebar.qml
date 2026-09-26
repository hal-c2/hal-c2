import OpenTUI

// The thread list: a filter field over the rows of `Shell.state.sidebar`.
// Typing filters (`sidebar.filter.set`), Enter keeps the filter
// (`sidebar.filter.commit`); the shell's Esc clears it. Plugins fill the
// "sidebar.footer" slot at the bottom; the "list" keymap moves the selection.
Rectangle {
    id: bar
    property alias filter: filterInput
    property alias footerMode: footerSlot.mode
    property alias keymap: listKeymap
    // Bound by the shell to the host's mode, so the field follows the keys.
    property bool filterFocused: false

    readonly property var sidebar: Shell.state.sidebar
    // Typing breaks a `text` binding, so follow the host's filter by hand
    // (Esc clears it there).
    readonly property string filterQuery: sidebar.filter
    onFilterQueryChanged: if (filterInput.text !== filterQuery) filterInput.text = filterQuery

    border.width: 1
    border.color: filterFocused ? Theme.colors.accent : Theme.colors.faint
    title: " Threads "
    titleColor: Theme.colors.dim
    color: Theme.colors.bg
    flexDirection: "column"
    paddingX: 1

    TextInput {
        id: filterInput
        objectName: "sidebarFilter"
        height: 1
        focus: bar.filterFocused
        placeholderText: "Filter threads (Ctrl+F)"
        color: Theme.colors.text
        focusedColor: Theme.colors.text
        backgroundColor: Theme.colors.bg
        focusedBackgroundColor: Theme.colors.bg
        onTextEdited: Shell.dispatch("sidebar.filter.set", { query: text })
        onAccepted: Shell.dispatch("sidebar.filter.commit")
    }

    Repeater {
        model: bar.sidebar.rows
        delegate: Item {
            flexDirection: "column"
            SidebarThreadRow {
                visible: modelData.kind === "thread"
                item: modelData.kind === "thread" ? modelData.thread : null
                active: modelData.kind === "thread" && modelData.selected
                section: modelData.kind === "thread" ? modelData.thread.section : ""
            }
            Text {
                visible: modelData.kind === "section"
                text: (modelData.expanded ? "▾ " : "▸ ") + modelData.title + " (" + modelData.count + ")"
                color: Theme.colors.dim
            }
            Text {
                visible: modelData.kind === "more"
                text: "  " + modelData.hiddenCount + " more…"
                color: Theme.colors.faint
            }
        }
    }

    Text {
        visible: bar.sidebar.rows.length === 0
        text: bar.sidebar.filter.length > 0 ? "No matching threads" : "No threads yet"
        color: Theme.colors.faint
    }

    Item { flexGrow: 1 }

    Slot {
        id: footerSlot
        objectName: "sidebarFooterSlot"
        name: "sidebar.footer"
        flexDirection: "column"
    }

    Keymap {
        id: listKeymap
        objectName: "listKeymap"
        name: "list"
        bindings: ({ "j": "next", "k": "previous" })
        handlers: ({
            next: () => Shell.dispatch("thread.next"),
            previous: () => Shell.dispatch("thread.previous")
        })
    }
}
