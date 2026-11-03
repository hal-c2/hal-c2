import OpenTUI

// "● Working for 12s" while a turn runs (Shell.state.timeline.working). The
// host says when its time next changes; the text moves once a second, never
// between.
Text {
    objectName: "workingIndicator"
    readonly property var working: Shell.state.timeline ? Shell.state.timeline.working : null
    visible: working !== null
    marginBottom: 1
    text: working ? working.text : ""

    Timer {
        interval: Math.max(1, working ? working.refreshInMs : 0)
        running: working !== null && working.refreshInMs > 0
        onTriggered: Shell.dispatch("timeline.tick")
    }
}
