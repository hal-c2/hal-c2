import OpenTUI

// The thread list, drawn like the OpenTUI client's Sidebar: the "HAL-C2"
// header (the logotype's orange and blue as the terminal's yellow and blue), a
// search box (click or Ctrl+F; typing dispatches
// `sidebar.filter.set`, Enter keeps the filter, the shell's Esc clears it),
// the project row (the scope picker and "+" to add a project), the "Threads"
// heading and the list. Plugins fill the "sidebar.footer" slot at the bottom.
//
// The host draws each row's lines to the pane's width and windows them to the
// list's height (`lines`), scrolled to keep the selection in view.
Rectangle {
    id: bar
    property alias filter: filterInput
    property alias footerMode: footerSlot.mode
    // Bound by the shell to the host's mode, so the field follows the keys.
    property bool filterFocused: false
    // The list has the keys (mode "list"); the OpenTUI client's list has no
    // focused look, so nothing changes here.
    property bool listFocused: false

    readonly property var sidebar: Shell.state.sidebar
    // Typing breaks a `text` binding, so follow the host's filter by hand
    // (Esc clears it there).
    readonly property string filterQuery: sidebar.filter
    onFilterQueryChanged: if (filterInput.text !== filterQuery) filterInput.text = filterQuery

    border.width: 1
    border.style: "rounded"
    border.color: Theme.colors.faint
    color: Theme.colors.bg
    flexDirection: "column"
    paddingX: 1
    overflow: "hidden"

    Item {
        objectName: "sidebarHeader"
        height: 1
        flexShrink: 0
        flexDirection: "row"
        Text { text: "HAL-"; font.bold: true; color: Theme.ansi("yellow") }
        Text { text: "C2"; font.bold: true; color: Theme.ansi("blue") }
    }

    Rectangle {
        objectName: "sidebarSearch"
        marginTop: 1
        flexShrink: 0
        flexDirection: "row"
        border.width: 1
        border.style: "rounded"
        border.color: bar.filterFocused ? Theme.colors.accent : Theme.colors.faint
        color: Theme.colors.bg
        paddingX: 1
        onMouseDown: (mouse) => Shell.dispatch("sidebar.filter.focus")

        Text {
            objectName: "sidebarSearchIcon"
            text: "⌕ "
            color: bar.filterFocused ? Theme.colors.accent : Theme.colors.dim
        }
        TextInput {
            id: filterInput
            objectName: "sidebarFilter"
            height: 1
            flexGrow: 1
            focus: bar.filterFocused
            placeholderText: "Search threads…"
            placeholderColor: Theme.colors.dim
            color: Theme.colors.text
            focusedColor: Theme.colors.text
            cursorColor: Theme.colors.accent
            backgroundColor: Theme.colors.bg
            focusedBackgroundColor: Theme.colors.bg
            onTextEdited: Shell.dispatch("sidebar.filter.set", { query: text })
            onAccepted: Shell.dispatch("sidebar.filter.commit")
        }
    }

    Item {
        objectName: "sidebarProjectRow"
        marginTop: 1
        marginBottom: 1
        height: 1
        flexShrink: 0
        flexDirection: "row"

        Text {
            objectName: "sidebarProjectScope"
            flexGrow: 1
            flexShrink: 1
            wrapMode: "none"
            truncate: true
            text: bar.sidebar.scopeLine
            onMouseDown: (mouse) => Shell.dispatch("sidebar.scopePicker.toggle")
        }
        Text {
            objectName: "sidebarAddProject"
            marginLeft: 1
            flexShrink: 0
            text: "+"
            color: Theme.colors.accent
            onMouseDown: (mouse) => Shell.dispatch("project.add")
        }
    }

    Text {
        height: 1
        flexShrink: 0
        text: "Threads"
        color: Theme.colors.accent
    }

    Text {
        visible: bar.sidebar.rows.length === 0
        flexShrink: 0
        text: "No threads here. Press ^N."
        color: Theme.colors.dim
    }

    Item {
        id: list
        objectName: "sidebarList"
        visible: bar.sidebar.rows.length > 0
        height: bar.sidebar.listRows
        flexShrink: 0
        flexDirection: "column"
        overflow: "hidden"
        onMouseScroll: (mouse) => {
            if (mouse.scroll && mouse.scroll.direction === "up") Shell.dispatch("sidebar.scroll", { by: -1 })
            else if (mouse.scroll && mouse.scroll.direction === "down") Shell.dispatch("sidebar.scroll", { by: 1 })
        }

        Repeater {
            model: bar.sidebar.lines
            delegate: SidebarThreadRow { line: modelData }
        }
    }

    Item { flexGrow: 1 }

    Slot {
        id: footerSlot
        objectName: "sidebarFooterSlot"
        name: "sidebar.footer"
        flexDirection: "column"
    }
}
