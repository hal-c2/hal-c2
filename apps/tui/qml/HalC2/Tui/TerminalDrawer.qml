import OpenTUI

// The thread's terminal drawer: a header, the numbered tabs and the active
// terminal's screen from `Shell.state.terminal`. The host runs the emulator;
// this paints its rows. While focused (`mode === "terminal"`) every key the
// shell's shortcuts leave goes to the running program.
Rectangle {
    id: drawer
    objectName: "terminalDrawer"
    readonly property var terminal: Shell.state.terminal
    readonly property bool focused: terminal.focused

    height: terminal.height
    flexShrink: 0
    border.width: 1
    border.color: focused ? Theme.colors.accent : Theme.colors.faint
    color: Theme.colors.bg
    flexDirection: "column"
    paddingX: 1

    Row {
        height: 1
        Text {
            flexShrink: 0
            text: "Terminal · " + drawer.terminal.title
            color: drawer.focused ? Theme.colors.accent : Theme.colors.warning
        }
        Text {
            flexGrow: 1
            flexShrink: 1
            truncate: true
            wrapMode: "none"
            text: drawer.focused
                ? " · ^P prompt · ^E close · ^↑/^↓ resize · ^O copy · paste ✓"
                : " · ^P focus · ^E close"
            color: Theme.colors.dim
        }
    }

    Row {
        objectName: "terminalTabs"
        height: 1
        Repeater {
            model: drawer.terminal.tabs
            delegate: Row {
                marginRight: 1
                Text {
                    text: (modelData.active ? "▸ " : "  ") + modelData.number
                    color: modelData.active ? Theme.colors.text : Theme.colors.dim
                    onMouseDown: Shell.dispatch("terminal.select", { id: modelData.id })
                }
                Text {
                    visible: modelData.active
                    text: " ✕"
                    color: Theme.colors.dim
                    onMouseDown: Shell.dispatch("terminal.close", { id: modelData.id })
                }
            }
        }
        Text {
            text: "+ new"
            color: Theme.colors.dim
            onMouseDown: Shell.dispatch("terminal.new")
        }
    }

    Item {
        id: screen
        objectName: "terminalScreen"
        flexGrow: 1
        flexDirection: "column"
        focusable: true
        focus: Shell.state.mode === "terminal"

        Text {
            objectName: "terminalScrollNote"
            visible: drawer.terminal.scrollNote.length > 0
            text: drawer.terminal.scrollNote
            color: Theme.colors.warning
        }
        Repeater {
            model: drawer.terminal.rowCount
            delegate: Text { text: drawer.terminal.lines[index] ?? " " }
        }

        Keys.onPressed: (event) => {
            if (event.sequence) {
                Shell.dispatch("terminal.input", { data: event.sequence })
                event.accepted = true
            }
        }
        Keys.onPaste: (event) => {
            Shell.dispatch("terminal.paste", { text: event.text })
            event.accepted = true
        }
        onMouseScroll: (mouse) => {
            if (mouse.scroll && mouse.scroll.direction === "up") Shell.dispatch("terminal.scroll", { action: "line-up" })
            else if (mouse.scroll && mouse.scroll.direction === "down") Shell.dispatch("terminal.scroll", { action: "line-down" })
        }
    }
}
