import OpenTUI

// Pick a checkpoint to revert the thread to (Shell.state.revert, RevertMenu in
// ThreadOverlays.tsx): a rounded error box above the prompt, newest first.
// Open in the host's "revert" mode: ↑/↓ select, Enter reverts, Esc cancels.
Rectangle {
    id: picker
    objectName: "revertPicker"
    readonly property var revert: Shell.state.revert

    visible: revert.open
    flexDirection: "column"
    flexShrink: 0
    border.width: 1
    border.style: "rounded"
    border.color: Theme.colors.error
    color: Theme.colors.bg
    paddingX: 1

    Text { text: picker.revert.title }
    Repeater {
        model: picker.revert.rows
        delegate: Text { height: 1; wrapMode: "none"; text: modelData.text }
    }
    Text {
        visible: picker.revert.rows.length === 0
        text: picker.revert.emptyText
        color: Theme.colors.faint
    }
    Text { text: picker.revert.hint; color: Theme.colors.dim }
}
