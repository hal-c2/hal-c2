import OpenTUI

// The keys the open thread adds right now (Shell.state.threadHints): ^Y with a
// plan, ^A/^R with approvals, or a warning while a question is set aside.
Text {
    objectName: "threadHints"
    readonly property var hints: Shell.state.threadHints
    visible: hints.banner !== null || hints.text !== ""
    text: hints.banner ?? hints.text
    color: hints.banner !== null ? Theme.colors.warning : Theme.colors.dim
}
