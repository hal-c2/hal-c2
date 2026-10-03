import OpenTUI

// The plan's progress (Shell.state.planStatus), under the timeline at its
// width: the agent's step list as it works through it, and the thread an
// implemented plan went to (a click opens it). The host styles the lines.
Item {
    id: panel
    objectName: "planStatus"
    readonly property var plan: Shell.state.planStatus

    visible: plan !== null
    flexDirection: "column"
    flexShrink: 0
    width: Shell.state.timeline.width
    alignSelf: "center"
    paddingX: 1

    Repeater {
        model: panel.plan !== null ? panel.plan.lines : []
        delegate: Text {
            height: 1
            flexShrink: 0
            wrapMode: "none"
            truncate: true
            text: modelData.text
            onMouseDown: if (modelData.action !== "") Shell.dispatch(modelData.action, modelData.payload)
        }
    }
}
