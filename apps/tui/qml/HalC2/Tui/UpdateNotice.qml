import OpenTUI

// The offer to update a server that is behind this app
// (`Shell.state.updateNotice`, null when there is none), over the
// conversation. [Update] opens the Updates page, × dismisses the notice for
// that version; both are palette commands too.
Item {
    id: notice
    objectName: "updateNotice"
    readonly property var offer: Shell.state.updateNotice

    visible: offer !== null
    flexDirection: "row"
    flexShrink: 0

    Text { flexShrink: 0; text: "⚠ "; color: Theme.colors.warning }
    Text {
        objectName: "updateNoticeText"
        flexGrow: 1
        flexShrink: 1
        text: notice.offer ? notice.offer.text : ""
        color: Theme.colors.text
    }
    Text {
        objectName: "updateNoticeAction"
        flexShrink: 0
        text: " [Update]"
        color: Theme.colors.accent
        onMouseDown: Shell.dispatch("section.open", { id: "updates" })
    }
    Text {
        objectName: "updateNoticeDismiss"
        flexShrink: 0
        text: " ×"
        color: Theme.colors.dim
        onMouseDown: Shell.dispatch("update.notice.dismiss")
    }
}
