import OpenTUI

// The prompt: attachments, the editor and the footer controls, all from
// `Shell.state.composer`. Enter sends (`composer.submit`), Shift+Enter adds a
// line; a paste that is an image (bytes or a path) becomes an attachment
// (`composer.paste` returns true and the text is not inserted). The editor is
// as tall as the host's layout says (`layout.editorRows`: 3 to 8 wrapped
// lines, then it scrolls inside itself). A new-thread draft
// (`Shell.state.newThread`) titles the frame and shows its workspace.
Rectangle {
    id: composer
    objectName: "composer"
    readonly property var model: Shell.state.composer
    readonly property var draft: Shell.state.newThread
    readonly property bool focused: Shell.state.mode === "compose" || Shell.state.mode === "newThread"
    property alias input: promptInput
    property alias footer: footerView

    border.width: 1
    border.color: focused ? Theme.colors.accent : Theme.colors.faint
    title: draft
        ? " New thread" + (draft.projectName !== null ? " · " + draft.projectName : "") + " "
        : ""
    titleColor: Theme.colors.dim
    color: Theme.colors.bg
    flexDirection: "column"
    flexShrink: 0
    paddingX: 1

    Text {
        objectName: "composerWorkspace"
        visible: !!composer.draft
        text: composer.draft
            ? (composer.draft.projectName !== null ? composer.draft.projectName : "no project")
                + " · " + composer.draft.workspaceLabel + " · " + (composer.draft.workspaceMode === "new-worktree" ? "base " : "branch ")
                + (composer.draft.branch !== null ? composer.draft.branch : "—")
                + (composer.draft.pending ? " (switching…)" : "")
            : ""
        color: Theme.colors.dim
    }

    Text {
        objectName: "composerAttachments"
        visible: composer.model.attachments.length > 0
        text: composer.model.attachments.map((a) => "[img " + a.name + "]").join(" ")
        color: Theme.colors.accent
    }

    TextArea {
        id: promptInput
        objectName: "composerInput"
        height: Shell.state.layout.editorRows
        flexShrink: 0
        focus: composer.focused
        placeholderText: composer.model.placeholder
        placeholderColor: Theme.colors.faint
        wrapMode: "word"
        // Plain Enter is taken by Keys.onPressed (send), ↑/↓ recall earlier prompts
        // when the prompt is empty; Shift+Enter and Ctrl+J add a line.
        keyBindings: [
            { name: "return", shift: true, action: "newline" },
            { name: "kpenter", shift: true, action: "newline" },
            { name: "linefeed", action: "newline" }
        ]
        color: Theme.colors.text
        focusedColor: Theme.colors.text
        backgroundColor: Theme.colors.bg
        focusedBackgroundColor: Theme.colors.bg
        // Typing breaks a `text` binding; follow the host's draft by hand
        // (sent, cleared, restored from the editor).
        readonly property string hostText: composer.model.text
        onHostTextChanged: if (text !== hostText) text = hostText
        onTextEdited: Shell.dispatch("composer.text.set", { text: text })
        Keys.onPressed: (event) => {
            if (event.key === "return" && !event.shift && !event.ctrl && !event.alt) {
                Shell.dispatch("composer.submit")
                event.accepted = true
            } else if ((event.key === "up" || event.key === "down") && !event.shift && !event.ctrl && !event.alt) {
                // Recall earlier prompts; the host declines when there is nothing to recall.
                event.accepted = Shell.dispatch(event.key === "up" ? "composer.history.previous" : "composer.history.next") === true
            }
        }
        Keys.onPaste: (event) => {
            const mimeType = event.metadata && event.metadata.mimeType ? event.metadata.mimeType : ""
            event.accepted = Shell.dispatch("composer.paste", { text: event.text, bytes: event.bytes, mimeType: mimeType }) === true
        }
    }

    ComposerFooter { id: footerView; objectName: "composerFooter" }
}
