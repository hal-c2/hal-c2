import OpenTUI

// Pick a checkpoint to revert the thread to (Shell.state.revert), newest first.
// Open in the host's "revert" mode: ↑/↓ select, Enter reverts, Esc cancels.
Rectangle {
    id: picker
    objectName: "revertPicker"
    readonly property var revert: Shell.state.revert
    readonly property bool live: Shell.state.mode === "revert"

    visible: revert.open
    flexDirection: "column"
    flexShrink: 0
    border.width: 1
    border.style: "rounded"
    border.color: Theme.colors.error
    paddingX: 1

    Text { text: picker.revert.title; color: Theme.colors.error }
    Repeater {
        model: picker.revert.rows
        delegate: Text {
            text: modelData.text
            color: modelData.active ? Theme.colors.text : Theme.colors.dim
        }
    }
    Text {
        visible: picker.revert.rows.length === 0
        text: picker.revert.emptyText
        color: Theme.colors.faint
    }
    Text { text: picker.revert.hint; color: Theme.colors.dim }

    Shortcut { sequence: "up"; enabled: picker.live; onActivated: Shell.dispatch("checkpoint.revert.move", { delta: -1 }) }
    Shortcut { sequence: "down"; enabled: picker.live; onActivated: Shell.dispatch("checkpoint.revert.move", { delta: 1 }) }
    Shortcut { sequence: "return"; enabled: picker.live; onActivated: Shell.dispatch("checkpoint.revert.confirm") }
    Shortcut { sequence: "escape"; enabled: picker.live; onActivated: Shell.dispatch("checkpoint.revert.cancel") }
}
