import OpenTUI

// The source-control action list (`Shell.state.git.actions`): the quick
// action first, then Commit / Push / PR. The highlighted row's hint (why it
// is disabled, or how it opens) sits below. A click runs the row.
Item {
    id: list
    objectName: "gitActions"
    readonly property var git: Shell.state.git
    property bool focused: false

    flexDirection: "column"

    Text { text: "actions"; color: Theme.colors.dim }
    Repeater {
        model: list.git.actions
        // One Text with a Span per row: a Text in a flex row keeps the width of
        // its first content, so changing labels must not sit in sibling Texts.
        delegate: Text {
            height: 1
            marginBottom: modelData.primary ? 1 : 0
            readonly property bool selected: index === list.git.selectedIndex
            onMouseDown: Shell.dispatch("git.activate", { index: index })
            text: selected ? "▸ " : "  "
            color: selected ? Theme.colors.accent : Theme.colors.dim
            Span {
                text: modelData.label + (modelData.kind === "url" ? " ↗" : "")
                color: modelData.disabled
                    ? Theme.colors.faint
                    : (selected && list.focused) || modelData.primary
                        ? Theme.colors.accent
                        : Theme.colors.text
            }
        }
    }
    Text {
        objectName: "gitHint"
        visible: list.git.selectedHint !== null
        text: "  " + (list.git.selectedHint ?? "")
        color: list.git.actions[list.git.selectedIndex]?.disabled ? Theme.colors.warning : Theme.colors.dim
        wrapMode: Text.Wrap
    }
}
