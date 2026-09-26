import OpenTUI

// The thread list: a filter field over the rows of `Shell.state.sidebar`.
// Typing filters (`sidebar.filter.set`), Enter keeps the filter
// (`sidebar.filter.commit`); the shell's Esc clears it. Plugins fill the
// "sidebar.footer" slot at the bottom. With the list focused (mode "list"),
// ShellKeymap's "list" keymap moves the selection.
//
// The host windows the rows (`visibleRows`) to the pane's height and scrolls
// them to keep the selection in view, so every row here is one line.
Rectangle {
    id: bar
    property alias filter: filterInput
    property alias footerMode: footerSlot.mode
    // Bound by the shell to the host's mode, so the field follows the keys.
    property bool filterFocused: false
    // The list has the keys (mode "list"): Esc hands them back.
    property bool listFocused: false

    readonly property var sidebar: Shell.state.sidebar
    // Typing breaks a `text` binding, so follow the host's filter by hand
    // (Esc clears it there).
    readonly property string filterQuery: sidebar.filter
    onFilterQueryChanged: if (filterInput.text !== filterQuery) filterInput.text = filterQuery

    border.width: 1
    border.color: filterFocused || listFocused ? Theme.colors.accent : Theme.colors.faint
    title: sidebar.scopeProjectKey === null ? " Threads " : " Threads · " + sidebar.scopeLabel + " "
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
        placeholderColor: Theme.colors.faint
        color: Theme.colors.text
        focusedColor: Theme.colors.text
        backgroundColor: Theme.colors.bg
        focusedBackgroundColor: Theme.colors.bg
        onTextEdited: Shell.dispatch("sidebar.filter.set", { query: text })
        onAccepted: Shell.dispatch("sidebar.filter.commit")
    }

    Repeater {
        model: bar.sidebar.visibleRows
        delegate: Item {
            flexDirection: "column"
            height: 1
            SidebarThreadRow {
                visible: modelData.kind === "thread"
                item: modelData.kind === "thread" ? modelData.thread : null
                active: modelData.kind === "thread" && modelData.selected
                section: modelData.kind === "thread" ? modelData.thread.section : ""
            }
            Text {
                visible: modelData.kind === "draft"
                text: modelData.kind === "draft"
                    ? "▌+ " + modelData.draft.label + " · " + modelData.projectName
                    : ""
                color: Theme.colors.accent
                truncate: true
            }
            Text {
                visible: modelData.kind === "section"
                text: modelData.kind === "section"
                    ? "  " + (modelData.expanded ? "▾ " : "▸ ") + modelData.title
                        + (modelData.expanded ? "" : " (" + modelData.count + ")") + " ─"
                    : ""
                color: modelData.section === "snoozed" ? Theme.colors.accent : Theme.colors.dim
                onMouseDown: (mouse) => Shell.dispatch("sidebar.section.toggle", { section: modelData.section })
            }
            Text {
                visible: modelData.kind === "more"
                text: modelData.kind === "more" ? "  + Show " + Math.min(modelData.hiddenCount, 25) + " more" : ""
                color: Theme.colors.dim
                onMouseDown: (mouse) => Shell.dispatch("sidebar.more")
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
}
