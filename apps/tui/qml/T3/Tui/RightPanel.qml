import OpenTUI

// The source-control panel: where the branch stands (`Shell.state.git`) and
// the actions that move it forward. Keys come from the shell's panel-mode
// shortcuts; a commit asks for its message at the bottom (commit mode).
Rectangle {
    id: panel
    objectName: "rightPanel"
    readonly property var git: Shell.state.git
    readonly property bool focused: Shell.state.rightPanel.focused
    readonly property var prompt: git.commitPrompt
    // Typing breaks a `text` binding: start each prompt empty by hand.
    onPromptChanged: commitInput.text = ""

    border.width: 1
    border.color: focused ? Theme.colors.accent : Theme.colors.faint
    title: panel.git.busy ? " Source Control · working… " : " Source Control "
    titleColor: panel.git.busy ? Theme.colors.warning : Theme.colors.text
    color: Theme.colors.bg
    flexDirection: "column"
    paddingX: 1

    Text {
        text: panel.focused ? "↑/↓ select · Enter run · Esc back" : "^L focus panel"
        color: Theme.colors.dim
    }
    Text {
        visible: !panel.git.available
        text: panel.git.busy ? "loading git status…" : "no git status"
        color: Theme.colors.dim
    }
    Item {
        objectName: "gitSummary"
        visible: panel.git.available
        flexDirection: "column"
        Item {
            flexDirection: "row"
            height: 1
            Text { text: "on "; color: Theme.colors.dim }
            Text { text: panel.git.branch ?? "(detached)"; color: Theme.colors.text }
        }
        Text {
            visible: panel.git.syncLine.length > 0
            text: panel.git.syncLine
            color: Theme.colors.dim
        }
        Text {
            visible: panel.git.prLine.length > 0
            text: panel.git.prLine
            color: panel.git.prState === "open"
                ? Theme.colors.success
                : panel.git.prState === "merged" ? Theme.ansi("magenta") : Theme.colors.dim
        }
        Text { text: panel.git.changesLine; color: Theme.colors.dim }
        Repeater {
            model: panel.git.files
            delegate: Text {
                text: "  " + modelData.path + "  +" + modelData.insertions + " -" + modelData.deletions
                color: modelData.color ? Theme.ansi(modelData.color) : Theme.colors.dim
            }
        }
    }

    GitActions { marginTop: 1; focused: panel.focused }

    Item {
        objectName: "commitPrompt"
        visible: panel.prompt !== null
        flexDirection: "column"
        marginTop: 1
        Text {
            text: "Commit message for " + (panel.prompt ? panel.prompt.label : "") + " · Enter commit · Esc cancel"
            color: Theme.colors.accent
            wrapMode: Text.Wrap
        }
        TextInput {
            id: commitInput
            objectName: "commitMessage"
            height: 1
            focus: Shell.state.mode === "commit"
            placeholderText: "Commit message"
            color: Theme.colors.text
            focusedColor: Theme.colors.text
            backgroundColor: Theme.colors.bg
            focusedBackgroundColor: Theme.colors.bg
            onAccepted: Shell.dispatch("git.commit", { message: text })
        }
    }
}
