pragma ComponentBehavior: Bound
import QtQuick

// A world of tiles, drawn in art pixels and scaled to fit, with one clock.
// What is inside it is in art pixels; `overlay` is over it, in screen pixels.
Flickable {
    id: root

    default property alias content: pixels.data
    // A list, not an alias: older Ljós lost a child given through one.
    property list<Item> overlay
    readonly property Item overlayItem: overlayLayer
    readonly property var world: root

    // What it is called, for screen readers.
    property string name: "World"
    // Round the world, where the view is wider or taller.
    property color backdrop: "transparent"
    property int columns: 20
    property int rows: 15
    property int tile: 16
    readonly property int pixelWidth: columns * tile
    readonly property int pixelHeight: rows * tile
    // Where someone with no tile goes when the world is full.
    property var entrance: [0, 0]

    // The clock runs only while the world is shown, active and busy.
    property bool active: Qt.application.state === Qt.ApplicationActive
    property bool busy: true
    readonly property bool shown: visible && active
    readonly property bool running: shown && busy
    // Whether the last tick left something moving: the clock is slower when not.
    property bool walking: false
    property real now: 0
    property int ticks: 0
    property real tickedAt: 0
    // Alternates every 300 ms of the world's time, to bob by.
    readonly property int bob: Math.floor(now / 300) % 2
    property bool stirred: false

    // The same seed and the same ticks give the same world.
    property int seed: 1
    property var rng: random(seed)

    property var actors: ({})
    property int actorCount: 0
    property int made: 0
    // tile index → the key of the actor that stops there.
    property var claims: ({})
    property var tiles: null
    property bool stale: true
    property list<QtObject> poses
    property real fontScale: 1

    // Whether the world is shown.
    property bool ready: true
    property string stageName: ""
    property string artName: ""

    // After every actor has moved. Call stir() in a handler that moved more.
    signal ticked(real dt)
    // The world is shown again, or the machine woke, over five seconds since
    // the last tick. It comes before anything that happens from then on.
    signal resumed
    signal tapped(int tx, int ty)
    // A listener let go of this tile.
    signal freed(int index)
    signal sheetPainted

    // As it is shown again, not at the clock's first tick.
    onShownChanged: if (shown) checkClock()
    clip: true
    contentWidth: Math.max(width, stageItem.width)
    contentHeight: Math.max(height, stageItem.height)
    boundsBehavior: Flickable.StopAtBounds
    Component.onCompleted: {
        for (let i = 0; i < overlay.length; i++)
            overlay[i].parent = overlayLayer;
    }

    // ── Camera ──

    // 1 fits the world in the view, by its width or height.
    property real zoom: 1
    property real margin: 8
    readonly property real devicePixelRatio: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
    readonly property real fitScale: pixelWidth > 0 && pixelHeight > 0 ? Math.max(0.01, Math.min((width - margin) / pixelWidth, (height - margin) / pixelHeight)) : 1
    readonly property real minScale: Math.min(1, fitScale)
    property real maxScale: 8
    readonly property real topScale: snapScale(maxScale)
    readonly property real pixelScale: zoom === 1 ? Math.max(minScale, Math.min(topScale, fitScale)) : snapScale(fitScale * zoom)
    // Nearest-neighbour art at a fractional scale has uneven pixels, so it is
    // drawn at the next whole device pixel and shrunk smoothly. From
    // `crispFrom` on, a zoom snaps to whole device pixels instead.
    readonly property int crispFrom: 4
    readonly property real drawScale: Math.ceil(pixelScale * devicePixelRatio - 0.001) / devicePixelRatio
    readonly property bool resampled: drawScale - pixelScale > 0.001

    function snapScale(wanted) {
        const ratio = devicePixelRatio;
        const scale = Math.max(minScale, Math.min(maxScale, wanted));
        const device = scale * ratio;
        return device >= crispFrom ? Math.min(Math.round(device), Math.floor(maxScale * ratio + 0.001)) / ratio : scale;
    }

    // Zooms from the scale shown, so in and out take the same steps.
    function zoomBy(factor) {
        const ratio = devicePixelRatio;
        let next = pixelScale * factor;
        if (next * ratio >= crispFrom) {
            const shown = factor > 1 ? Math.floor(pixelScale * ratio + 0.001) : Math.ceil(pixelScale * ratio - 0.001);
            const step = Math.round(next * ratio);
            next = (factor > 1 ? Math.max(step, shown + 1) : Math.min(step, shown - 1)) / ratio;
        }
        zoom = Math.max(minScale, Math.min(maxScale, next)) / fitScale;
    }

    // Scrolls just enough to show `item`.
    function reveal(item) {
        const r = item.mapToItem(contentItem, 0, 0, item.width, item.height);
        const fit = (at, size, view, content, start) => {
            let next = at;
            if (start < next)
                next = start;
            else if (start + size > next + view)
                next = start + size - view;
            return Math.max(0, Math.min(Math.max(0, content - view), next));
        };
        contentX = fit(contentX, r.width, width, contentWidth, r.x);
        contentY = fit(contentY, r.height, height, contentHeight, r.y);
    }

    // ── Randomness ──

    function hash(text) {
        let h = 2166136261;
        for (let i = 0; i < text.length; i++) {
            h ^= text.charCodeAt(i);
            h = Math.imul(h, 16777619);
        }
        return h >>> 0;
    }

    function random(from) {
        let s = from >>> 0;
        return () => {
            s = (s + 0x6D2B79F5) >>> 0;
            let t = s;
            t = Math.imul(t ^ (t >>> 15), t | 1);
            t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
            return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
        };
    }

    function pick(draw, list) {
        return list[Math.floor(draw() * list.length)];
    }

    function between(draw, low, high) {
        return low + draw() * (high - low);
    }

    // ── Colours ──

    // "#rrggbb" darker for `by` below 0, lighter above, as far as -1 and 1.
    function shade(color, by) {
        const n = parseInt(color.slice(1), 16);
        const parts = [n >> 16, (n >> 8) & 255, n & 255].map(v => by < 0 ? v * (1 + by) : v + (255 - v) * by);
        return "#" + parts.map(v => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, "0")).join("");
    }

    // ── Tiles ──

    onColumnsChanged: changed()
    onRowsChanged: changed()

    // A Thing or Spot changed: the tiles are read again before they are next used.
    function changed() {
        stale = true;
    }

    // Reads the tiles from the Things and Spots, in the order they are written.
    function compile() {
        const W = columns, H = rows;
        const grid = new Uint8Array(W * H);
        const spots = [];
        const inside = (x, y) => x >= 0 && y >= 0 && x < W && y < H;
        const read = (item, left, top) => {
            const children = item.children;
            for (let i = 0; i < children.length; i++) {
                const child = children[i];
                if (child.isActor)
                    continue;
                let x = left, y = top;
                if (child.isThing) {
                    x += child.tx;
                    y += child.ty;
                    if (child.solid) {
                        for (let ay = y; ay < y + child.rows; ay++) {
                            for (let ax = x; ax < x + child.columns; ax++) {
                                if (inside(ax, ay))
                                    grid[ay * W + ax] = 1;
                            }
                        }
                    }
                } else if (child.isSpot) {
                    const spot = {
                        x: x + child.tx,
                        y: y + child.ty,
                        kind: child.kind,
                        face: Math.max(0, ["down", "left", "right", "up"].indexOf(child.face)),
                        offY: child.offY,
                        pose: child.pose
                    };
                    if (child.area)
                        spot.area = child.area;
                    if (child.seat)
                        spot.seat = true;
                    spots.push(Object.assign(spot, child.extra));
                }
                read(child, x, y);
            }
        };
        read(pixels, 0, 0);
        for (const spot of spots) {
            if (spot.seat && inside(spot.x, spot.y))
                grid[spot.y * W + spot.x] = 2;
        }
        tiles = { cols: W, rows: H, grid: grid, spots: spots };
        stale = false;
        return tiles;
    }

    function sameFloor(one, other) {
        if (one.cols !== other.cols || one.rows !== other.rows)
            return false;
        for (let i = 0; i < one.grid.length; i++) {
            if (one.grid[i] !== other.grid[i])
                return false;
        }
        return true;
    }

    function plan() {
        return stale || !tiles ? compile() : tiles;
    }

    function walkable(x, y) {
        return x >= 0 && y >= 0 && x < columns && y < rows && plan().grid[y * columns + x] === 0;
    }

    // The nearest floor nobody else claimed, west of `before` when given, or null.
    function nearestFree(x, y, key, before) {
        const W = columns, H = rows, grid = plan().grid;
        const seen = new Uint8Array(W * H);
        const queue = [[Math.max(0, Math.min(W - 1, x)), Math.max(0, Math.min(H - 1, y))]];
        seen[queue[0][1] * W + queue[0][0]] = 1;
        while (queue.length) {
            const [cx, cy] = queue.shift();
            const i = cy * W + cx;
            if (grid[i] === 0 && !(cx >= before) && (!claims[i] || claims[i] === key))
                return [cx, cy];
            for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
                const nx = cx + dx, ny = cy + dy;
                if (nx >= 0 && ny >= 0 && nx < W && ny < H && !seen[ny * W + nx]) {
                    seen[ny * W + nx] = 1;
                    queue.push([nx, ny]);
                }
            }
        }
        return null;
    }

    // A*, four ways, round what is solid and through people. A seat is
    // entered only as the goal. The tiles to step on, or null.
    function path(sx, sy, gx, gy) {
        const W = columns, H = rows;
        const start = sy * W + sx, goal = gy * W + gx;
        if (start === goal)
            return [];
        const grid = plan().grid;
        const g = new Int32Array(W * H).fill(-1);
        const from = new Int32Array(W * H).fill(-1);
        const heap = [];
        const push = (f, i) => {
            heap.push([f, i]);
            let k = heap.length - 1;
            while (k > 0) {
                const up = (k - 1) >> 1;
                if (heap[up][0] <= heap[k][0])
                    break;
                [heap[up], heap[k]] = [heap[k], heap[up]];
                k = up;
            }
        };
        const pop = () => {
            const top = heap[0];
            const last = heap.pop();
            if (heap.length) {
                heap[0] = last;
                let k = 0;
                for (;;) {
                    const l = 2 * k + 1, r = l + 1;
                    let m = k;
                    if (l < heap.length && heap[l][0] < heap[m][0])
                        m = l;
                    if (r < heap.length && heap[r][0] < heap[m][0])
                        m = r;
                    if (m === k)
                        break;
                    [heap[m], heap[k]] = [heap[k], heap[m]];
                    k = m;
                }
            }
            return top;
        };
        g[start] = 0;
        push(Math.abs(gx - sx) + Math.abs(gy - sy), start);
        while (heap.length) {
            const [, i] = pop();
            if (i === goal)
                break;
            const x = i % W, y = (i - x) / W;
            for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
                const nx = x + dx, ny = y + dy;
                if (nx < 0 || ny < 0 || nx >= W || ny >= H)
                    continue;
                const j = ny * W + nx;
                if (j !== goal && grid[j] !== 0)
                    continue;
                const cost = g[i] + 1;
                if (g[j] < 0 || cost < g[j]) {
                    g[j] = cost;
                    from[j] = i;
                    push(cost + Math.abs(gx - nx) + Math.abs(gy - ny), j);
                }
            }
        }
        if (g[goal] < 0)
            return null;
        const steps = [];
        for (let i = goal; i !== start; i = from[i])
            steps.push(i);
        return steps.reverse();
    }

    // ── Claims: where each actor stops is its own ──

    function free(spot, actor) {
        const holder = claims[spot.y * columns + spot.x];
        return !holder || holder === actor.key;
    }

    function release(actor) {
        if (actor.claim >= 0 && actor.claim !== actor.hold && claims[actor.claim] === actor.key)
            delete claims[actor.claim];
        actor.claim = -1;
    }

    function claim(actor, spot) {
        release(actor);
        const i = spot.y * columns + spot.x;
        claims[i] = actor.key;
        actor.claim = i;
    }

    // A listener keeps the tile it stopped on, besides the one it is going to.
    function holdHere(actor) {
        const i = actor.ty * columns + actor.tx;
        if (claims[i] === undefined || claims[i] === actor.key) {
            claims[i] = actor.key;
            actor.hold = i;
        }
    }

    function letGo(actor) {
        const i = actor.hold;
        actor.hold = -1;
        if (i < 0 || i === actor.claim || claims[i] !== actor.key)
            return;
        delete claims[i];
        freed(i);
    }

    // A free Spot of a kind, the actor's own if it has one, claimed.
    function spotFor(actor, kind, pose) {
        const options = plan().spots.filter(s => s.kind === kind && free(s, actor));
        if (!options.length)
            return null;
        const spot = options.find(s => s.x === actor.goal?.x && s.y === actor.goal?.y) ?? pick(rng, options);
        claim(actor, spot);
        return Object.assign({}, spot, { pose: pose || spot.pose });
    }

    // ── Actors ──

    readonly property alias talks: talker

    Talks {
        id: talker
        world: root
    }

    function join(actor) {
        if (!actor.key)
            actor.key = "actor-" + (++made);
        if (actor.manual || actors[actor.key] === actor)
            return;
        const replaces = !!actors[actor.key];
        actors[actor.key] = actor;
        if (!replaces)
            actorCount++;
        walking = true;
    }

    function leave(actor) {
        if (!actor || actor.gone)
            return;
        actor.gone = true;
        letGo(actor);
        release(actor);
        if (actors[actor.key] !== actor)
            return;
        delete actors[actor.key];
        actorCount--;
        for (const other of Object.values(actors)) {
            if (other.talk && other.talk.to === actor.key)
                talker.end(other);
            if (other.heldBy === actor.key) {
                other.heldBy = "";
                letGo(other);
            }
        }
    }

    // ── The clock ──

    // Runs `n` ticks of 40 ms at once, for tests and previews.
    function advance(n) {
        for (let i = 0; i < n; i++)
            tick(40);
    }

    function stir() {
        stirred = true;
    }

    function checkClock() {
        const wall = Date.now();
        const stood = wall - tickedAt > 5000;
        tickedAt = wall;
        if (stood)
            resumed();
    }

    function tick(dt) {
        if (columns <= 0 || rows <= 0)
            return;
        if (stale || !tiles) {
            const before = tiles;
            compile();
            // Only walls and seats change a walk, so only they plan it again.
            if (before && !sameFloor(before, tiles)) {
                for (const actor of Object.values(actors))
                    actor.route();
            }
        }
        now += dt;
        ticks++;
        stirred = false;
        let any = false;
        for (const key of Object.keys(actors)) {
            const actor = actors[key];
            if (!actor)
                continue;
            actor.think();
            if (actor.step(dt))
                any = true;
            actor.show();
        }
        ticked(dt);
        walking = any || stirred;
    }

    Timer {
        interval: root.walking ? 40 : 200
        repeat: true
        running: root.running
        onTriggered: {
            root.checkClock();
            root.tick(interval);
        }
    }

    // ── Sheets are painted a few a frame ──

    property var sheetQueue: []
    property int sheetsPending: 0
    property real sheetBudget: 10
    property real sheetCost: 0
    property string painterName: ""

    function queueSheet(sheet) {
        sheet.painting = "queued";
        sheetQueue.push(sheet);
        sheetsPending++;
    }

    function dropSheet(sheet) {
        const i = sheetQueue.indexOf(sheet);
        if (i >= 0)
            sheetQueue.splice(i, 1);
        if (sheet.painting === "queued" || sheet.painting === "due")
            sheetsPending--;
        sheet.painting = "";
    }

    // Those in an item that is going: it is destroyed only later.
    function dropSheets(item) {
        for (let i = 0; i < item.children.length; i++) {
            const child = item.children[i];
            if (child.requestSheet)
                dropSheet(child);
            else
                dropSheets(child);
        }
    }

    // One until it is known what a sheet takes, then as many as the budget allows.
    function paintSheets() {
        let n = sheetCost > 0 ? Math.max(1, Math.floor(sheetBudget / sheetCost)) : 1;
        const waiting = [];
        while (n > 0 && sheetQueue.length) {
            const sheet = sheetQueue.shift();
            if (!sheet.paintable) {
                waiting.push(sheet);
                continue;
            }
            sheet.painting = "due";
            sheet.requestSheet();
            n--;
        }
        sheetQueue = waiting.concat(sheetQueue);
    }

    function sheetDone(sheet, ms) {
        if (sheet.painting !== "due")
            return;
        sheet.painting = "painted";
        // Date.now() counts whole milliseconds; a sheet takes at least one.
        const cost = Math.max(1, ms);
        sheetCost = sheetCost > 0 ? 0.7 * sheetCost + 0.3 * cost : cost;
        sheetsPending--;
        sheetPainted();
    }

    Timer {
        objectName: root.painterName
        interval: 16
        repeat: true
        running: root.visible && root.sheetsPending > 0
        onTriggered: root.paintSheets()
    }

    // ── The view ──

    Rectangle {
        parent: root
        anchors.fill: parent
        z: -1
        visible: root.backdrop.a > 0
        color: root.backdrop
    }

    Item {
        id: stageItem

        objectName: root.stageName
        opacity: root.ready ? 1 : 0
        x: Math.max(0, (root.width - width) / 2)
        y: Math.max(0, (root.height - height) / 2)
        width: root.pixelWidth * root.pixelScale
        height: root.pixelHeight * root.pixelScale

        Item {
            objectName: root.artName
            width: root.pixelWidth * root.drawScale
            height: root.pixelHeight * root.drawScale
            scale: root.pixelScale / root.drawScale
            transformOrigin: Item.TopLeft
            layer.enabled: root.resampled
            layer.smooth: true

            Item {
                id: pixels

                readonly property var world: root

                width: root.pixelWidth
                height: root.pixelHeight
                scale: root.drawScale
                transformOrigin: Item.TopLeft
                Accessible.role: Accessible.Pane
                Accessible.name: root.name

                // Tiles only: what can be activated is a Touchable, which keys reach.
                TapHandler {
                    onTapped: point => {
                        if (root.ready)
                            root.tapped(Math.floor(point.position.x / root.tile), Math.floor(point.position.y / root.tile));
                    }
                }
            }
        }

        Item {
            id: overlayLayer

            readonly property var world: root

            anchors.fill: parent
        }
    }
}
