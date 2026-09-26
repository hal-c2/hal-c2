import OpenTUI

// "● Working… 12s" while a turn runs (Shell.state.timeline.working). Static:
// the seconds move when the thread does, never on a timer.
Text {
    objectName: "workingIndicator"
    readonly property var working: Shell.state.timeline ? Shell.state.timeline.working : null
    visible: working !== null
    marginTop: 1
    text: working ? working.text : ""
}
