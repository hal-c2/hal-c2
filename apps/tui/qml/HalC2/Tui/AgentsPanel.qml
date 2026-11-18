import OpenTUI

// The agents panel: the open thread's workers (`Shell.state.agents`, drawn to
// the panel and windowed by the host). A worker waiting on the user, for an
// approval or an answer, sits first in the warning colour. Keys come from the
// shell's agents-mode shortcuts; a click selects, a second click on the same
// worker opens it. A panel too short for one whole worker (`agents.compact`)
// drops its title and hint and draws the selected worker on the lines it has.
Rectangle {
    id: panel
    objectName: "agentsPanel"
    readonly property var agents: Shell.state.agents
    // The keys, not the layout's flag: a click on the prompt takes them without closing the panel.
    readonly property bool focused: Shell.state.mode === "agents"
    // The worker the mouse last clicked: the host's first highlight is not a click.
    property string clickedId: ""
    // The highlighted worker. Once the keys move the highlight off the clicked one,
    // that click no longer counts: coming back to it, a click selects it again.
    readonly property string selectedId: {
        const rows = agents.rows
        for (let i = 0; i < rows.length; i++) if (rows[i].selected) return rows[i].id
        return ""
    }
    onSelectedIdChanged: if (selectedId !== clickedId) clickedId = ""

    border.width: 1
    border.style: "rounded"
    border.color: focused ? Theme.colors.accent : Theme.colors.faint
    color: Theme.colors.bg
    flexDirection: "column"
    paddingX: 1

    function tone(state) {
        switch (state) {
        case "blocked": return Theme.colors.warning
        case "working": return Theme.colors.accent
        case "completed": return Theme.colors.success
        case "failed": return Theme.colors.error
        default: return Theme.colors.dim
        }
    }

    // Elapsed times move once a second, only while something still works.
    Timer {
        interval: 1000
        running: panel.agents.live
        onTriggered: {
            Shell.dispatch("agents.tick")
            restart()
        }
    }

    Text {
        objectName: "agentsTitle"
        visible: !panel.agents.compact
        height: 1
        wrapMode: "none"
        Bold { text: "Agents"; color: Theme.colors.text }
        Span {
            text: panel.agents.summary.length > 0 ? " · " + panel.agents.summary : ""
            color: panel.agents.blocked > 0 ? Theme.colors.warning : Theme.colors.dim
        }
    }
    Text {
        visible: !panel.agents.compact
        height: 1
        wrapMode: "none"
        truncate: true
        text: panel.focused
            ? "Enter open · c interrupt · Esc"
            : "^X a focus"
        color: Theme.colors.dim
    }
    Text {
        objectName: "agentsParent"
        visible: panel.agents.parent !== null
        height: 1
        wrapMode: "none"
        truncate: true
        onMouseDown: Shell.dispatch("agents.parent")
        text: "↳ "
        color: Theme.colors.dim
        Span { text: panel.agents.parent ?? ""; color: Theme.colors.accent }
        Span { text: panel.focused ? " · u back" : ""; color: Theme.colors.dim }
    }
    Text {
        objectName: "agentsEmpty"
        visible: panel.agents.rows.length === 0
        height: 1
        text: "No workers in this thread"
        color: Theme.colors.dim
    }
    Text {
        visible: panel.agents.above > 0
        height: 1
        text: "↑ " + panel.agents.above + " more"
        color: Theme.colors.dim
    }
    Repeater {
        model: panel.agents.rows
        // Three lines a worker: title and time, state and model, latest activity.
        delegate: Rectangle {
            objectName: "agentRow"
            flexShrink: 0
            flexDirection: "column"
            height: modelData.lines
            color: modelData.selected ? Theme.colors.selectedBg : Theme.colors.bg
            onMouseDown: {
                const again = modelData.selected && panel.clickedId === modelData.id
                panel.clickedId = modelData.id
                Shell.dispatch(again ? "agents.open" : "agents.select", { index: modelData.index })
            }
            Text {
                height: 1
                wrapMode: "none"
                text: modelData.glyph + " "
                color: panel.tone(modelData.state)
                Span {
                    text: modelData.title
                    color: modelData.state === "blocked" ? Theme.colors.warning : Theme.colors.text
                }
                Span {
                    text: modelData.elapsed.length > 0 ? " " + modelData.elapsed : ""
                    color: Theme.colors.dim
                }
            }
            Text {
                visible: modelData.lines >= 2
                height: 1
                wrapMode: "none"
                text: "  "
                Span { text: modelData.stateLabel; color: panel.tone(modelData.state) }
                Span { text: modelData.meta; color: Theme.colors.dim }
            }
            Text {
                visible: modelData.lines >= 3
                height: 1
                wrapMode: "none"
                text: "  " + modelData.activity
                color: Theme.colors.dim
            }
        }
    }
    Text {
        visible: panel.agents.below > 0
        height: 1
        text: "↓ " + panel.agents.below + " more"
        color: Theme.colors.dim
    }
}
