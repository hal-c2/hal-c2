import OpenTUI

// The agent's question inside the composer, like ComposerPendingUserInputPanel
// (Shell.state.userInput, styled by the host): the header, the question, the
// options around the highlight and the key hint. The typed answer is the
// composer's editor row. Keys live in the host's "userInput" mode; Esc sets
// the question aside and ^U (in the prompt) brings it back.
Item {
    id: panel
    objectName: "pendingUserInput"
    readonly property var input: Shell.state.userInput

    visible: Shell.state.composer.answering
    flexDirection: "column"
    flexShrink: 0
    marginBottom: 1

    Text { text: panel.input.headerLine ?? "" }
    Text { text: panel.input.questionLine ?? ""; color: Theme.colors.text }
    Repeater {
        model: panel.input.options
        delegate: Text { text: modelData.line }
    }
    Text { text: panel.input.hint ?? ""; color: Theme.colors.dim }
}
