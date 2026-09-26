import OpenTUI

// The source-control panel (RightPanel.tsx): where the branch stands
// (`Shell.state.git`, clipped to the panel by the host) and the actions that
// move it forward. Keys come from the shell's panel-mode
// shortcuts; a commit asks for its message at the bottom (commit mode).
Rectangle {
    id: panel
    objectName: "sourceControlPanel"
    readonly property var git: Shell.state.git
    readonly property bool focused: Shell.state.layout.rightPanel.focused
    readonly property var prompt: git.commitPrompt
    // Typing breaks a `text` binding: start each prompt empty by hand.
    onPromptChanged: commitInput.text = ""

    border.width: 1
    border.style: "rounded"
    border.color: focused ? Theme.colors.accent : Theme.colors.faint
    color: Theme.colors.bg
    flexDirection: "column"
    paddingX: 1

    Text {
        objectName: "sourceControlTitle"
        Bold { text: "Source Control"; color: Theme.colors.text }
        Span { text: panel.git.busy ? " · working…" : ""; color: Theme.colors.warning }
    }
    Text {
        text: panel.focused ? "↑/↓ select · Enter activate · Esc back" : "^L focus panel"
        color: Theme.colors.dim
    }
    Text {
        visible: !panel.git.available
        text: panel.git.busy ? "  loading git status…" : "  no git status"
        color: Theme.colors.dim
    }
    Item {
        objectName: "gitSummary"
        visible: panel.git.available
        flexDirection: "column"
        Text {
            objectName: "gitBranch"
            text: "on "
            color: Theme.colors.dim
            Span { text: panel.git.branchText; color: Theme.colors.text }
        }
        Text {
            visible: panel.git.syncLine.length > 0
            text: panel.git.syncLine
            color: Theme.colors.dim
        }
        Text {
            objectName: "gitPullRequest"
            visible: panel.git.prLabel.length > 0
            Link {
                href: panel.git.prUrl ?? ""
                Span {
                    text: panel.git.prLabel
                    color: panel.git.prState === "open"
                        ? Theme.colors.success
                        : panel.git.prState === "merged" ? Theme.ansi("magenta") : Theme.colors.dim
                }
                Span { text: panel.git.prStateLabel; color: Theme.colors.dim }
            }
        }
        Text { text: panel.git.changesLine; color: Theme.colors.dim }
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
            placeholderColor: Theme.colors.faint
            color: Theme.colors.text
            focusedColor: Theme.colors.text
            backgroundColor: Theme.colors.bg
            focusedBackgroundColor: Theme.colors.bg
            onAccepted: Shell.dispatch("git.commit", { message: text })
        }
    }
}
