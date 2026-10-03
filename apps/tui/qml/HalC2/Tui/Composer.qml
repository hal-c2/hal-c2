import OpenTUI

// The prompt, like ChatComposer in ComposerDock: a rounded faint box as wide
// as `composer.surfaceWidth`, centred in the conversation column, holding the
// agent's question, the attachment chips, the editor row and the footer; the
// checkout context (`composer.context`) sits under it. The editor row is the
// editor while the prompt has the keys (`composer.inputFocused`), the answer
// field while a single-choice question is open, and otherwise a caption
// (`composer.caption`: "^P prompt · …"). Enter sends (`composer.submit`),
// Shift+Enter adds a line; a paste that is an image (bytes or a path) becomes
// an attachment (`composer.paste` returns true and the text is not inserted).
// The editor is as tall as the host's layout says (`layout.editorRows`).
// Renaming a thread, writing a commit message or pasting a cluster invite
// swaps the box for a one-line prompt in the accent colour (ChatComposer's
// rename and commit modes).
Item {
    id: dock
    objectName: "composerDock"
    readonly property var model: Shell.state.composer
    readonly property var question: Shell.state.userInput
    readonly property bool showEditor: model.inputFocused && !model.answering
    readonly property bool showAnswer: model.inputFocused && model.answering && !(question.multiSelect ?? false)
    property alias input: promptInput
    property alias answer: answerInput
    property alias footer: footerView
    // How plugins' "composer.actions" contributions sit next to the built-in controls.
    property alias actionsMode: footerView.actionsMode
    // "rename", "commit", "join" or "" (the prompt itself).
    readonly property string auxMode: Shell.state.mode === "rename" && Shell.state.overlay !== null
        ? "rename"
        : Shell.state.mode === "commit" && Shell.state.git.commitPrompt !== null ? "commit"
        : Shell.state.mode === "join" && Shell.state.cluster.joining ? "join"
        : Shell.state.mode === "ask" && Shell.state.ask !== null ? "ask" : ""
    // What the box is asking for: the mode's name, or the host's question (`ask.label`).
    readonly property string auxLabel: auxMode === "ask" ? Shell.state.ask.label : auxMode
    // Prefill the title each time a rename opens, and start each commit message
    // empty (typing breaks a `text` binding).
    onAuxModeChanged: {
        if (auxMode === "rename") renameInput.text = Shell.state.overlay.title
        if (auxMode === "commit") commitInput.text = ""
        if (auxMode === "join") joinInput.text = ""
    }
    // One question can follow another without the mode changing.
    readonly property int askSeq: Shell.state.ask !== null ? Shell.state.ask.seq : 0
    onAskSeqChanged: if (Shell.state.ask !== null) askInput.text = Shell.state.ask.value

    width: model.surfaceWidth
    alignSelf: "center"
    flexDirection: "column"
    flexShrink: 0

    Rectangle {
        objectName: "composerAux"
        visible: dock.auxMode !== ""
        border.width: 1
        border.style: "rounded"
        border.color: Theme.colors.accent
        color: Theme.colors.bg
        flexDirection: "column"
        flexShrink: 0
        paddingX: 1

        Item {
            flexDirection: "row"
            height: 1
            Text {
                flexShrink: 0
                text: dock.auxLabel + " ▸ "
                color: Theme.colors.accent
            }
            TextInput {
                id: askInput
                objectName: "askInput"
                visible: dock.auxMode === "ask"
                flexGrow: 1
                height: 1
                focus: dock.auxMode === "ask"
                placeholderText: Shell.state.ask !== null ? Shell.state.ask.placeholder : ""
                placeholderColor: Theme.colors.dim
                cursorColor: Theme.colors.accent
                color: Theme.colors.text
                focusedColor: Theme.colors.text
                backgroundColor: Theme.colors.bg
                focusedBackgroundColor: Theme.colors.bg
                onAccepted: Shell.dispatch("ask.submit", { text: text })
            }
            TextInput {
                id: renameInput
                objectName: "renameInput"
                visible: dock.auxMode === "rename"
                flexGrow: 1
                height: 1
                focus: dock.auxMode === "rename"
                placeholderText: "New thread title…"
                placeholderColor: Theme.colors.dim
                cursorColor: Theme.colors.accent
                color: Theme.colors.text
                focusedColor: Theme.colors.text
                backgroundColor: Theme.colors.bg
                focusedBackgroundColor: Theme.colors.bg
                onAccepted: Shell.dispatch("thread.rename", { key: Shell.state.overlay.threadKey, title: text })
            }
            TextInput {
                id: commitInput
                objectName: "commitMessage"
                visible: dock.auxMode === "commit"
                flexGrow: 1
                height: 1
                focus: dock.auxMode === "commit"
                placeholderText: "Commit message…"
                placeholderColor: Theme.colors.dim
                cursorColor: Theme.colors.accent
                color: Theme.colors.text
                focusedColor: Theme.colors.text
                backgroundColor: Theme.colors.bg
                focusedBackgroundColor: Theme.colors.bg
                onAccepted: Shell.dispatch("git.commit", { message: text })
            }
            TextInput {
                id: joinInput
                objectName: "clusterJoinLink"
                visible: dock.auxMode === "join"
                flexGrow: 1
                height: 1
                focus: dock.auxMode === "join"
                placeholderText: "Invite link from the other machine…"
                placeholderColor: Theme.colors.dim
                cursorColor: Theme.colors.accent
                color: Theme.colors.text
                focusedColor: Theme.colors.text
                backgroundColor: Theme.colors.bg
                focusedBackgroundColor: Theme.colors.bg
                onAccepted: Shell.dispatch("cluster.join", { link: text })
            }
        }
        Text {
            text: (dock.auxMode === "ask" ? "Enter accept" : "Enter " + dock.auxMode) + " · Esc cancel"
            color: Theme.colors.dim
        }
    }

    Rectangle {
        id: frame
        objectName: "composer"
        visible: dock.auxMode === ""
        border.width: 1
        border.style: "rounded"
        border.color: Theme.colors.faint
        color: Theme.colors.bg
        flexDirection: "column"
        flexShrink: 0
        paddingX: 1

        PendingUserInput {}

        // The provider cannot run a turn (signed out, disabled): what to do about it.
        Item {
            objectName: "composerNotice"
            visible: dock.model.notice !== null
            flexDirection: "column"
            flexShrink: 0
            Repeater {
                model: dock.model.noticeLines
                delegate: Text {
                    height: 1
                    flexShrink: 0
                    wrapMode: "none"
                    text: (index === 0 ? "⚠ " : "  ") + modelData
                    color: Theme.colors.warning
                }
            }
        }

        // Files referenced with "@": a click on a chip drops it and its mention.
        Item {
            objectName: "composerReferences"
            visible: dock.model.references.length > 0
            flexDirection: "row"
            height: 1
            flexShrink: 0
            overflow: "hidden"
            Repeater {
                model: dock.model.references
                delegate: Text {
                    objectName: "composerReference-" + modelData.path
                    marginRight: 1
                    flexShrink: 0
                    wrapMode: "none"
                    onMouseDown: Shell.dispatch("composer.reference.remove", { path: modelData.path })
                    Span { text: "× "; color: Theme.colors.accent }
                    Span { text: modelData.label; color: Theme.colors.text }
                }
            }
        }

        Item {
            objectName: "composerAttachments"
            visible: dock.model.attachments.length > 0
            flexDirection: "row"
            flexShrink: 0
            Repeater {
                model: dock.model.visibleAttachments
                delegate: Item {
                    objectName: "composerAttachment-" + modelData.name
                    width: 14
                    marginRight: 1
                    flexDirection: "column"
                    onMouseDown: Shell.dispatch("composer.attachment.remove", { id: modelData.id })
                    Item {
                        flexDirection: "row"
                        height: 1
                        Text { text: "× "; color: Theme.colors.accent }
                        Text { text: modelData.label; color: Theme.colors.text }
                    }
                    Image {
                        visible: modelData.image !== null
                        width: 8
                        height: 3
                        fit: "fill"
                        protocol: "kitty"
                        source: modelData.image ? modelData.image.source : null
                    }
                }
            }
            Text {
                visible: dock.model.moreAttachments !== ""
                text: dock.model.moreAttachments
                color: Theme.colors.dim
                // Squeezed by the chips on a narrow composer, as in the OpenTUI client.
                flexShrink: 1
            }
        }

        Item {
            objectName: "composerEditorRow"
            flexDirection: "row"
            height: dock.model.answering ? 1 : Shell.state.layout.editorRows
            flexShrink: 0
            overflow: "hidden"
            onMouseDown: Shell.dispatch("composer.focus")

            TextArea {
                id: promptInput
                objectName: "composerInput"
                visible: dock.showEditor
                // The focus binding can land before the editor is shown again (a
                // hidden renderable drops focus), so take it once it is visible.
                onVisibleChanged: if (visible && dock.showEditor) forceActiveFocus()
                flexGrow: 1
                height: Shell.state.layout.editorRows
                focus: dock.showEditor
                placeholderText: dock.model.placeholder
                placeholderColor: Theme.colors.dim
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
                readonly property string hostText: dock.model.text
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
            // A typed answer to a single-choice question; it wins over the options.
            TextInput {
                id: answerInput
                objectName: "userInputAnswer"
                visible: dock.showAnswer
                onVisibleChanged: if (visible && focus === false && Shell.state.mode === "userInput") forceActiveFocus()
                flexGrow: 1
                height: 1
                focus: dock.showAnswer && Shell.state.mode === "userInput"
                placeholderText: "Type your own answer, or leave blank to use the selected option"
                placeholderColor: Theme.colors.dim
                color: Theme.colors.text
                focusedColor: Theme.colors.text
                backgroundColor: Theme.colors.bg
                focusedBackgroundColor: Theme.colors.bg
                // Typing breaks a `text` binding, so follow the host's answer by hand.
                readonly property string hostText: dock.question.pending ? dock.question.customAnswer : ""
                onHostTextChanged: if (text !== hostText) text = hostText
                onTextEdited: Shell.dispatch("userInput.answer.set", { text: text })
                // A focused field keeps Enter from window shortcuts, so it submits itself.
                onAccepted: Shell.dispatch("userInput.submit")
            }
            Text {
                objectName: "composerCaption"
                visible: !dock.showEditor && !dock.showAnswer
                flexGrow: 1
                text: dock.model.caption
            }
        }

        ComposerFooter { id: footerView; objectName: "composerFooter" }
    }

    Item {
        objectName: "composerContext"
        visible: dock.model.context !== null
        flexDirection: "row"
        flexShrink: 0
        paddingX: 1
        Text {
            objectName: "composerWorkspace"
            flexShrink: 0
            text: dock.model.context ? dock.model.context.workspace : ""
            color: Theme.colors.dim
            onMouseDown: if (dock.model.context && dock.model.context.pickable) Shell.dispatch("composer.workspacePicker.toggle")
        }
        Item { flexGrow: 1 }
        Text {
            objectName: "composerBranch"
            flexShrink: 0
            text: dock.model.context ? dock.model.context.branch : ""
            color: Theme.colors.dim
            onMouseDown: if (dock.model.context && dock.model.context.pickable) Shell.dispatch("composer.branchPicker.toggle")
        }
    }
}
