import QtQuick

// A sprite sheet, painted once in the World's paint budget and then only moved.
// `draw(frame, row)` returns rects [x, y, width, height, color], or three
// lists of them: [under, outlined, over]. Draw the side row facing left.
Item {
    id: sheet

    readonly property var world: {
        let above = parent;
        while (above && above.world === undefined)
            above = above.parent;
        return above?.world ?? null;
    }
    property int columns: 1
    property int rows: 1
    property int cellWidth: 16
    property int cellHeight: 16
    // Between cells, so a scaled one never samples the next.
    property int gap: 2
    property int frame: 0
    // 0 down, 1 left, 2 right, 3 up, as an Actor's `dir`.
    property int facing: 0
    property int row: rows >= 3 ? [0, 1, 1, 2][facing] : 0
    property bool mirrored: facing === 2
    property var draw: (frame, row) => []
    property var key: null
    property color outline: "#211d2a"

    property string painting: ""
    readonly property bool paintable: canvas.available

    width: cellWidth
    height: cellHeight
    clip: true

    function requestSheet() {
        canvas.requestPaint();
    }
    function requeue() {
        if (!world)
            return;
        world.dropSheet(sheet);
        world.queueSheet(sheet);
    }
    onKeyChanged: if (painting) requeue()
    Component.onCompleted: requeue()
    Component.onDestruction: world?.dropSheet?.(sheet)

    function paintCell(ctx, parts, left, top) {
        let style = "";
        const fill = (x, y, w, h, color) => {
            const x0 = Math.max(0, x), y0 = Math.max(0, y);
            const x1 = Math.min(cellWidth, x + w), y1 = Math.min(cellHeight, y + h);
            if (x1 <= x0 || y1 <= y0)
                return;
            if (color !== style) {
                ctx.fillStyle = color;
                style = color;
            }
            ctx.fillRect(left + x0, top + y0, x1 - x0, y1 - y0);
        };
        const layered = parts.length > 0 && (parts[0].length === 0 || typeof parts[0][0] !== "number");
        for (const r of layered ? parts[0] : parts)
            fill(r[0], r[1], r[2], r[3], r[4]);
        if (!layered)
            return;
        const edge = String(outline);
        for (const r of parts[1])
            fill(r[0] - 1, r[1] - 1, r[2] + 2, r[3] + 2, edge);
        for (const r of parts[1])
            fill(r[0], r[1], r[2], r[3], r[4]);
        for (const r of parts[2])
            fill(r[0], r[1], r[2], r[3], r[4]);
    }

    Canvas {
        id: canvas

        x: -sheet.frame * (sheet.cellWidth + sheet.gap)
        y: -sheet.row * (sheet.cellHeight + sheet.gap)
        width: sheet.columns * (sheet.cellWidth + sheet.gap)
        height: sheet.rows * (sheet.cellHeight + sheet.gap)
        smooth: false
        antialiasing: false
        transform: Scale {
            origin.x: sheet.frame * (sheet.cellWidth + sheet.gap) + sheet.cellWidth / 2
            xScale: sheet.mirrored ? -1 : 1
        }
        onPaint: {
            if (sheet.painting === "queued")
                return;
            const began = Date.now();
            const ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            for (let r = 0; r < sheet.rows; r++) {
                for (let f = 0; f < sheet.columns; f++)
                    sheet.paintCell(ctx, sheet.draw(f, r), f * (sheet.cellWidth + sheet.gap), r * (sheet.cellHeight + sheet.gap));
            }
            sheet.world?.sheetDone(sheet, Date.now() - began);
        }
    }
}
