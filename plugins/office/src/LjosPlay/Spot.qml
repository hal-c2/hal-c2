import QtQuick

// A tile actors go to, to do something. Inside a Thing it counts from the
// Thing's top left tile.
Item {
    id: spot

    readonly property bool isSpot: true
    readonly property var world: {
        let above = parent;
        while (above && above.world === undefined)
            above = above.parent;
        return above?.world ?? null;
    }
    property string kind: ""
    property int tx: 0
    property int ty: 0
    // "down", "left", "right" or "up".
    property string face: "down"
    // Art pixels an actor moves down by there, to sit on something.
    property real offY: 0
    property string pose: ""
    property string area: ""
    // A seat is walked onto only by whoever is going there.
    property bool seat: false
    // Anything else the goal made from this spot should carry.
    property var extra: ({})

    onTxChanged: world?.changed()
    onTyChanged: world?.changed()
    onKindChanged: world?.changed()
    onFaceChanged: world?.changed()
    onOffYChanged: world?.changed()
    onPoseChanged: world?.changed()
    onAreaChanged: world?.changed()
    onSeatChanged: world?.changed()
    onExtraChanged: world?.changed()
    Component.onCompleted: world?.changed()
    Component.onDestruction: world?.changed?.()
}
