import OpenTUI

// The delete confirmation (`Shell.state.overlay` of kind "confirmDelete",
// ConfirmDeleteMenu in ThreadOverlays.tsx): a rounded error box above the
// prompt. y confirms, n or Esc cancels (shell keys). Renaming is a prompt in
// the composer's place (Composer).
Rectangle {
    id: overlay
    objectName: "threadOverlay"
    readonly property var state: Shell.state.overlay
    readonly property bool confirming: state !== null && state.kind === "confirmDelete"

    visible: confirming
    flexShrink: 0
    border.width: 1
    border.style: "rounded"
    border.color: Theme.colors.error
    color: Theme.colors.bg
    flexDirection: "column"
    paddingX: 1

    Text {
        objectName: "confirmDeleteText"
        text: overlay.confirming ? overlay.state.line : ""
    }
    Text {
        text: "y delete · n / Esc cancel"
        color: Theme.colors.dim
    }
}
