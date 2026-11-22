import QtQuick

// A picture painted once, and again only when what draws it changes. `draw`
// is a list of [x, y, width, height, color], or a function(ctx, width, height).
// It fills its parent unless given a size.
Canvas {
    id: art

    property var draw: []
    // Change it to paint again when a `draw` function's inputs change.
    property var key: null

    width: parent ? parent.width : 0
    height: parent ? parent.height : 0
    smooth: false
    antialiasing: false
    onDrawChanged: requestPaint()
    onKeyChanged: requestPaint()
    onPaint: {
        const ctx = getContext("2d");
        ctx.clearRect(0, 0, width, height);
        if (typeof draw === "function") {
            draw(ctx, width, height);
            return;
        }
        for (const part of draw ?? []) {
            ctx.fillStyle = part[4];
            ctx.fillRect(part[0], part[1], part[2], part[3]);
        }
    }
}
