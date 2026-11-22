import QtQuick

// Something on the tiles. A solid one is walked round. Its children are drawn
// in art pixels from its top left; a Spot in it counts tiles from there.
Item {
    id: thing

    readonly property bool isThing: true
    readonly property var world: {
        let above = parent;
        while (above && above.world === undefined)
            above = above.parent;
        return above?.world ?? null;
    }
    property int tx: 0
    property int ty: 0
    property int columns: 1
    property int rows: 1
    property bool solid: false
    readonly property int tile: world?.tile ?? 16

    x: tx * tile
    y: (ty + rows) * tile - height
    z: (ty + rows) * tile
    width: columns * tile
    height: rows * tile

    onTxChanged: world?.changed()
    onTyChanged: world?.changed()
    onColumnsChanged: world?.changed()
    onRowsChanged: world?.changed()
    onSolidChanged: world?.changed()
    Component.onCompleted: world?.changed()
    Component.onDestruction: world?.changed?.()
}
