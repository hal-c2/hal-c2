import OpenTUI

// The rename prompt and the delete confirmation (`Shell.state.overlay`),
// shown in the prompt's place. Rename: Enter saves (`thread.rename {key,
// title}`), Esc cancels. Delete: y confirms, n or Esc cancels (shell keys).
Rectangle {
    id: overlay
    objectName: "threadOverlay"
    readonly property var state: Shell.state.overlay
    readonly property bool renaming: state !== null && state.kind === "rename"
    // Prefill the field each time a rename opens (typing breaks a `text` binding).
    onRenamingChanged: if (renaming) renameInput.text = state.title

    visible: state !== null
    flexShrink: 0
    border.width: 1
    border.color: state !== null && state.kind === "confirmDelete" ? Theme.colors.error : Theme.colors.accent
    title: renaming ? " Rename thread " : " Delete thread "
    titleColor: Theme.colors.dim
    color: Theme.colors.bg
    flexDirection: "column"
    paddingX: 1

    TextInput {
        id: renameInput
        objectName: "renameInput"
        visible: overlay.renaming
        height: 1
        focus: overlay.renaming && Shell.state.mode === "rename"
        color: Theme.colors.text
        focusedColor: Theme.colors.text
        backgroundColor: Theme.colors.bg
        focusedBackgroundColor: Theme.colors.bg
        onAccepted: Shell.dispatch("thread.rename", { key: overlay.state.threadKey, title: text })
    }
    Text {
        visible: overlay.renaming
        text: "Enter save · Esc cancel"
        color: Theme.colors.faint
    }
    Text {
        objectName: "confirmDeleteText"
        visible: overlay.state !== null && overlay.state.kind === "confirmDelete"
        text: overlay.state !== null ? "delete " + overlay.state.title + " — this can't be undone" : ""
        color: Theme.colors.error
        truncate: true
    }
    Text {
        visible: overlay.state !== null && overlay.state.kind === "confirmDelete"
        text: "y delete · n / Esc cancel"
        color: Theme.colors.faint
    }
}
