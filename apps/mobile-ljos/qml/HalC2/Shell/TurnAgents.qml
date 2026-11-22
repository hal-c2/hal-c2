import QtQuick

// Stands in for mobile-qt's C++ TurnAgents (TurnAgents.h), so
// ThreadScreen loads (#1624). The real one is the subagents of a
// thread's latest turn as a list model (roles agentId, title, status,
// statusLabel, running, elapsed, thread) with a `summary` ("2 of 3
// agents working") read from its `timeline`, ticking while `active`.
// Its Rust port reads the same TimelineModel the shell's AgentsModel
// does; that is H1 (#1659). Until then no turn has agents to show, and
// ThreadScreen's agents row stays away, as a turn with none leaves it.
QtObject {
    property var timeline: null
    property bool active: false
    readonly property string summary: ""
    readonly property int count: 0
}
