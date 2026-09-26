import OpenTUI

// The prompt's frame: an editor sized by the host (`layout.editorRows`, 3 to
// 8 wrapped lines, then it scrolls inside itself). Edits report the text
// (`composer.text.set`) so the host can size the rows around it.
Rectangle {
    id: prompt
    objectName: "prompt"
    readonly property var layout: Shell.state.layout

    height: layout.composerRows
    flexShrink: 0
    border.width: 1
    border.color: Shell.state.mode === "compose" ? Theme.colors.accent : Theme.colors.faint
    color: Theme.colors.bg
    flexDirection: "column"
    paddingX: 1

    TextArea {
        id: editor
        objectName: "promptInput"
        height: prompt.layout.editorRows
        flexShrink: 0
        focus: Shell.state.mode === "compose"
        wrapMode: "word"
        placeholderText: "Ask anything"
        onTextEdited: Shell.dispatch("composer.text.set", { text: text })
    }
}
