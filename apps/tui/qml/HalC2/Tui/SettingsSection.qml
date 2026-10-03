import OpenTUI

// A settings page the terminal can change (`Shell.state.settingsSection`:
// scheduled tasks, diagnostics, storage, …) in the conversation's place. The
// host paints the rows that fit and marks the selected one; ↑/↓ move, Enter
// runs the row, Esc goes back (the `section` keymap). A row that takes text
// opens the one-line field under the rows (`input`; Enter saves, Esc cancels),
// and a step that must be confirmed shows its question there (`confirm`; y / n).
Rectangle {
    id: page
    objectName: "settingsSection"
    readonly property var section: Shell.state.settingsSection
    readonly property var input: section.input
    readonly property var confirm: section.confirm
    // Typing breaks a `text` binding, so the field is filled each time it opens.
    readonly property int inputSeq: input ? input.seq : 0
    onInputSeqChanged: if (input) field.text = input.value

    border.width: 1
    border.style: "rounded"
    border.color: Theme.colors.accent
    color: Theme.colors.bg
    flexDirection: "column"
    paddingX: 1

    Text {
        objectName: "settingsSectionHeader"
        flexShrink: 0
        wrapMode: "none"
        truncate: true
        text: page.section.title
        color: Theme.colors.accent
        Span { text: "  ·  " + page.section.hint; color: Theme.colors.dim }
    }
    Repeater {
        model: page.section.rows
        delegate: Rectangle {
            flexShrink: 0
            height: 1
            color: modelData.selected ? Theme.colors.selectedBg : Theme.colors.bg
            onMouseDown: if (modelData.selectable) Shell.dispatch("section.activate", { id: modelData.id })
            Text {
                wrapMode: "none"
                truncate: true
                text: modelData.line
            }
        }
    }
    Item { flexGrow: 1; flexShrink: 1 }
    Item {
        objectName: "settingsSectionConfirm"
        visible: page.confirm !== null
        flexDirection: "column"
        flexShrink: 0
        Repeater {
            model: page.confirm ? page.confirm.lines : []
            delegate: Text { height: 1; wrapMode: "none"; text: modelData; color: Theme.colors.warning }
        }
        Text { text: page.confirm ? page.confirm.hint : ""; color: Theme.colors.dim }
    }
    Item {
        objectName: "settingsSectionInput"
        visible: page.input !== null
        flexDirection: "column"
        flexShrink: 0
        Item {
            flexDirection: "row"
            height: 1
            Text {
                flexShrink: 0
                text: (page.input ? page.input.label : "") + " ▸ "
                color: Theme.colors.accent
            }
            TextInput {
                id: field
                objectName: "settingsSectionField"
                flexGrow: 1
                height: 1
                focus: page.input !== null
                onVisibleChanged: if (visible && page.input !== null) forceActiveFocus()
                placeholderText: page.input ? page.input.placeholder : ""
                placeholderColor: Theme.colors.dim
                cursorColor: Theme.colors.accent
                color: Theme.colors.text
                focusedColor: Theme.colors.text
                backgroundColor: Theme.colors.bg
                focusedBackgroundColor: Theme.colors.bg
                onAccepted: Shell.dispatch("section.input.submit", { text: text })
            }
        }
        Text { text: "Enter save · Esc cancel"; color: Theme.colors.dim }
    }
}
