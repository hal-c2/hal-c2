import OpenTUI

// The agent's question inside the composer (Shell.state.userInput): options
// to move through and pick, and a field for a typed answer, which wins.
// Keys live in the host's "userInput" mode; Esc sets the question aside and
// ^U (in the prompt) brings it back.
Rectangle {
    id: panel
    objectName: "pendingUserInput"
    readonly property var input: Shell.state.userInput
    readonly property bool live: Shell.state.mode === "userInput"
    // Typing breaks a `text` binding, so follow the host's answer by hand.
    readonly property string answer: input.pending ? input.customAnswer : ""
    onAnswerChanged: if (answerInput.text !== answer) answerInput.text = answer

    visible: input.active
    flexDirection: "column"
    flexShrink: 0
    border.width: 1
    border.style: "rounded"
    border.color: Theme.colors.accent
    paddingX: 1

    Item {
        flexDirection: "row"
        Text { text: panel.input.header ?? ""; color: Theme.colors.accent; font.bold: true }
        Text {
            visible: (panel.input.countText ?? "") !== ""
            text: "  " + (panel.input.countText ?? "")
            color: Theme.colors.dim
        }
    }
    Text { wrapMode: "word"; text: panel.input.question ?? ""; color: Theme.colors.text }
    Repeater {
        model: panel.input.options
        delegate: Text {
            text: modelData.text
            color: modelData.highlighted ? Theme.colors.accent : Theme.colors.text
        }
    }
    TextInput {
        id: answerInput
        objectName: "userInputAnswer"
        visible: !(panel.input.multiSelect ?? false)
        height: 1
        focus: panel.live && !(panel.input.multiSelect ?? false)
        placeholderText: "or type an answer"
        placeholderColor: Theme.colors.faint
        color: Theme.colors.text
        focusedColor: Theme.colors.text
        backgroundColor: Theme.colors.bg
        focusedBackgroundColor: Theme.colors.bg
        onTextEdited: Shell.dispatch("userInput.answer.set", { text: text })
        // A focused field keeps Enter from window shortcuts, so it submits itself.
        onAccepted: Shell.dispatch("userInput.submit")
    }
    Item {
        flexDirection: "row"
        Text {
            objectName: "userInputSubmit"
            flexShrink: 0
            text: "[ " + (panel.input.primaryActionLabel ?? "") + " ]"
            color: Theme.colors.accent
            onMouseDown: Shell.dispatch("userInput.submit")
        }
        Text {
            flexShrink: 1
            wrapMode: "none"
            truncate: true
            text: "  " + (panel.input.hint ?? "")
            color: Theme.colors.dim
        }
    }

    Shortcut { sequence: "up"; enabled: panel.live; onActivated: Shell.dispatch("userInput.move", { delta: -1 }) }
    Shortcut { sequence: "down"; enabled: panel.live; onActivated: Shell.dispatch("userInput.move", { delta: 1 }) }
    Shortcut {
        sequence: "space"
        enabled: panel.live && (panel.input.multiSelect ?? false)
        onActivated: Shell.dispatch("userInput.toggle")
    }
    Shortcut { sequence: "return"; enabled: panel.live; onActivated: Shell.dispatch("userInput.submit") }
    Shortcut { sequence: "escape"; enabled: panel.live; onActivated: Shell.dispatch("userInput.defer") }
}
