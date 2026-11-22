import QtQuick

// One thing an Actor can do. An actor does the first of its activities whose
// `when` is true, and looks again when that changes or a stay ends.
QtObject {
    // Its name, the actor's `plan`. A name that changes is a different plan.
    property string name: ""
    property bool when: true

    // Where it is done, one of: a kind of Spot, a tile [x, y], a random tile,
    // or whatever `goal(actor)` returns.
    property string spot: ""
    property var at: null
    property bool wander: false
    property var goal: null

    // The Pose shown there; a Spot's own when empty.
    property string pose: ""
    // How long it stays, in ms: a number, or [least, most]. Forever when null.
    property var stay: null
    // Whether the stay waits for the goal, or starts wherever the actor stops.
    property bool mustArrive: true
    // Whether the stay counts only at a seat: resting is sitting, not waiting.
    property bool mustSit: false
    // Plans this one leaves running.
    property var keep: []

    // Every time it is the activity to do, whether or not that is a change.
    signal chosen(var actor)
    // The stay is over. The actor decides again unless the handler already
    // gave it something to do or a later `until`.
    signal ended(var actor)
}
