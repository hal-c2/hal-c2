pragma ComponentBehavior: Bound
import QtQuick

// Someone in a World. It does the first of its `activities` whose `when` is
// true, walking to where that is done. Its children are what it looks like;
// `overhead` is above its head, in screen pixels and over everything.
Item {
    id: actor

    readonly property bool isActor: true
    property var world: {
        let above = parent;
        while (above && above.world === undefined)
            above = above.parent;
        return above?.world ?? null;
    }
    property var crowd: null
    property string key: ""
    // What a Crowd made it for.
    property var entry: null
    // Moved by you (step(), show()), not by the world's clock.
    property bool manual: false
    property bool gone: false

    // Where it starts, and then where it is: the tile, and in art pixels.
    property int tx: -1
    property int ty: -1
    property real px: 0
    property real py: 0
    readonly property int tile: world?.tile ?? 16

    property list<QtObject> activities
    // A list, not an alias: older Ljós lost a child given through one.
    property list<Item> overhead

    // Frames, for a Sheet bound to `frame` and `dir`.
    property var walkFrames: [0]
    property int standFrame: 0
    property int sitFrame: standFrame
    property int talkFrame: standFrame
    // function(goal, time) → a frame, or null for the goal's Pose.
    property var frameFor: null
    // function(talk) → what it answers when talked to.
    property var reply: talk => "!"
    property real headX: width / 2
    property real headY: 0
    property string bubbleName: ""
    // Art pixels a second.
    property real speed: 50

    // What it is doing.
    property string plan: ""
    property var goal: null
    property var path: []
    property int next: -1
    property int claim: -1
    property int hold: -1
    property real until: 0
    property var stay: null
    property int frame: 0
    property int dir: 0
    property real dist: 0
    property real offY: 0
    property var talk: null
    property var queue: []
    property string heldBy: ""
    property int face: -1
    property string bubble: ""
    property real bubbleUntil: 0
    property var doing: null
    property bool due: true

    readonly property bool stopped: next < 0 && path.length === 0
    readonly property bool arrived: goal !== null && stopped && tx === goal.x && ty === goal.y
    readonly property var wanted: {
        for (let i = 0; i < activities.length; i++) {
            if (activities[i].when)
                return activities[i];
        }
        return null;
    }
    readonly property string wantedPlan: wanted?.name ?? ""

    // It got to its goal.
    signal reached(var goal)

    width: tile
    height: tile
    x: px
    y: py - (height - tile) + offY
    z: py + tile
    visible: tx >= 0

    onWantedChanged: wake()
    onWantedPlanChanged: wake()

    function wake() {
        due = true;
        if (world && tx >= 0)
            world.walking = true;
    }

    Component.onCompleted: {
        for (let i = 0; i < overhead.length; i++)
            overhead[i].parent = head;
        if (!world)
            return;
        if (tx >= 0) {
            px = tx * tile;
            py = ty * tile;
        }
        world.join(actor);
    }
    Component.onDestruction: world?.leave?.(actor)

    function choice() {
        for (let i = 0; i < activities.length; i++) {
            if (activities[i].when)
                return activities[i];
        }
        return null;
    }

    function goalOf(activity) {
        if (activity.goal)
            return activity.goal(actor);
        if (activity.spot)
            return world.spotFor(actor, activity.spot, activity.pose);
        let tileAt = activity.at;
        if (activity.wander)
            tileAt = world.nearestFree(Math.floor(world.rng() * world.columns), Math.floor(world.rng() * world.rows), key);
        if (!tileAt)
            return null;
        const spot = { x: tileAt[0], y: tileAt[1], face: 0, offY: 0, pose: activity.pose, kind: activity.name };
        if (!world.free(spot, actor))
            return null;
        world.claim(actor, spot);
        return spot;
    }

    // Works out what to do, and goes to do it when that changed or `force`.
    function decide(force) {
        if (!world)
            return;
        due = false;
        if (talk)
            return;
        // As `when` is now, which can be ahead of `wanted`.
        const activity = choice();
        if (!activity)
            return;
        activity.chosen(actor);
        if (!force && goal && (plan === activity.name || activity.keep.includes(plan)))
            return;
        begin(activity);
    }

    // Does an activity now, whatever its `when` says.
    function begin(activity) {
        const to = goalOf(activity);
        doing = activity;
        stay = activity.stay;
        until = Infinity;
        plan = activity.name;
        setGoal(to);
    }

    function setGoal(to) {
        const same = goal && to && goal.x === to.x && goal.y === to.y;
        goal = to;
        if (!to || tx < 0)
            return;
        if (!same || (path.length === 0 && next < 0 && (tx !== to.x || ty !== to.y)))
            route();
        world.walking = true;
    }

    // Walks to a tile, or the nearest free one to it. False when there is none.
    function walkTo(x, y) {
        const to = world.walkable(x, y) && world.free({ x: x, y: y }, actor) ? [x, y] : world.nearestFree(x, y, key);
        if (!to)
            return false;
        const spot = { x: to[0], y: to[1], face: 0, offY: 0, pose: "", kind: "walk" };
        world.claim(actor, spot);
        doing = null;
        stay = null;
        plan = "walk";
        setGoal(spot);
        if (stopped && tx === spot.x && ty === spot.y)
            reached(goal);
        return true;
    }

    // Walks up to another actor to say something. The line's id, for reword().
    function tell(other, text, kind) {
        const id = ++world.made;
        queue.push({ id: id, to: typeof other === "string" ? other : other.key, text: text, kind: kind });
        world.walking = true;
        return id;
    }

    // New words for a line it waits to say, walks over to say, or is saying.
    function reword(id, text) {
        for (const line of queue) {
            if (line.id === id)
                line.text = text;
        }
        if (!talk || talk.id !== id)
            return;
        talk.text = world.talks.spoken(text);
        if (talk.phase === "say")
            bubble = talk.text;
    }

    function say(text, ms) {
        bubble = text;
        bubbleUntil = world.now + (ms ?? 3000);
    }

    // Plans from its tile, or the one it is stepping onto.
    function route() {
        if (!goal || tx < 0)
            return;
        const W = world.columns;
        const sx = next >= 0 ? next % W : tx;
        const sy = next >= 0 ? (next - sx) / W : ty;
        path = world.path(sx, sy, goal.x, goal.y) ?? [];
    }

    // Puts it on a tile. Off the floor, or with `snap` on something that is
    // not where it is going, on the nearest free floor.
    function place(x, y, snap) {
        const W = world.columns;
        const inside = x >= 0 && y >= 0 && x < W && y < world.rows;
        if (!inside || snap && !(world.walkable(x, y) || (goal && goal.x === x && goal.y === y))) {
            const spare = world.nearestFree(x, y, key) ?? world.entrance;
            x = spare[0];
            y = spare[1];
        }
        tx = x;
        ty = y;
        px = x * tile;
        py = y * tile;
        next = -1;
    }

    // One tick of deciding.
    function think() {
        const talks = world.talks;
        if (!talk && queue.length && tx >= 0 && !talks.held(actor))
            talks.begin(actor);
        if (talk) {
            talks.step(actor);
        } else if (tx >= 0) {
            if (due)
                decide(false);
            else if (!goal && world.ticks % 8 === 0)
                decide(true);
            else if (staying())
                linger();
        }
        if (bubble && world.now >= bubbleUntil && !(talk && talk.phase === "say"))
            bubble = "";
    }

    // Whether the stay of what it is doing counts now.
    function staying() {
        if (!doing || !goal || stay === null || next >= 0 || path.length)
            return false;
        if (doing.mustSit && !goal.seat)
            return false;
        return !doing.mustArrive || (tx === goal.x && ty === goal.y);
    }

    function linger() {
        if (until === Infinity) {
            until = world.now + (typeof stay === "number" ? stay : world.between(world.rng, stay[0], stay[1]));
            return;
        }
        if (world.now < until)
            return;
        const over = doing, was = until;
        over.ended(actor);
        if (doing === over && until === was)
            decide(true);
    }

    // One tick along its path. It walks through others, and stops only on a
    // tile of its own.
    function step(dt) {
        const W = world.columns;
        if (next < 0 && path.length && world.talks.held(actor))
            return false;
        if (next < 0 && path.length) {
            const n = path.shift();
            next = n;
            const toX = n % W, toY = (n - toX) / W;
            dir = toX < tx ? 1 : toX > tx ? 2 : toY < ty ? 3 : 0;
            offY = 0;
        }
        if (next < 0)
            return false;
        const nx = next % W, ny = (next - nx) / W;
        const stride = Math.max(1, Math.round(dt * speed / 1000));
        const toPx = nx * tile, toPy = ny * tile;
        px += Math.sign(toPx - px) * Math.min(stride, Math.abs(toPx - px));
        py += Math.sign(toPy - py) * Math.min(stride, Math.abs(toPy - py));
        dist += stride;
        if (px === toPx && py === toPy) {
            tx = nx;
            ty = ny;
            next = -1;
            if (path.length === 0 && goal && tx === goal.x && ty === goal.y)
                reached(goal);
        }
        return true;
    }

    // The frame for what it is doing.
    function show() {
        if (next >= 0) {
            frame = walkFrames[Math.floor(dist / 5) % walkFrames.length];
            return;
        }
        if (talk && talk.phase !== "go") {
            frame = talk.phase === "say" && Math.floor(world.now / 300) % 2 ? talkFrame : standFrame;
            return;
        }
        const at = !!goal && tx === goal.x && ty === goal.y && path.length === 0;
        if (bubble && !talk) {
            frame = Math.floor(world.now / 300) % 2 ? talkFrame : at && goal.seat ? sitFrame : standFrame;
            if (face >= 0)
                dir = face;
            return;
        }
        if (!at) {
            frame = standFrame;
            if (face >= 0)
                dir = face;
            return;
        }
        dir = face >= 0 ? face : goal.face ?? 0;
        offY = goal.offY ?? 0;
        let shown = frameFor ? frameFor(goal, world.now) : null;
        if (shown === null || shown === undefined) {
            shown = goal.seat ? sitFrame : standFrame;
            const poses = world.poses;
            for (let i = 0; i < poses.length; i++) {
                if (poses[i].name === goal.pose) {
                    shown = poses[i].frameAt(world.now);
                    break;
                }
            }
        }
        frame = shown;
    }

    Item {
        id: head

        readonly property var world: actor.world

        parent: actor.world?.overlayItem ?? actor
        visible: actor.visible
        x: (actor.x + actor.headX) * (world?.pixelScale ?? 1)
        y: (actor.y + actor.headY) * (world?.pixelScale ?? 1)
        z: actor.bubble ? 2 : 1

        Rectangle {
            id: speech

            objectName: actor.bubbleName
            visible: actor.bubble !== ""
            x: Math.max(-head.x, Math.min((head.parent?.width ?? 0) - head.x - width, -width / 2))
            y: -height - 3 * (head.world?.pixelScale ?? 1)
            width: Math.min(220, speechText.implicitWidth + 16)
            height: speechText.implicitHeight + 10
            color: "#fbf8f1"
            border.color: "#211d2a"
            border.width: 2

            Text {
                id: speechText

                anchors.centerIn: parent
                width: Math.min(204, implicitWidth)
                text: actor.bubble
                textFormat: Text.PlainText
                color: "#211d2a"
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
                font.pixelSize: Math.round(12 * (head.world?.fontScale ?? 1))
                font.weight: Font.Medium
            }

            Rectangle {
                x: -speech.x - 4
                y: speech.height - 2
                width: 8
                height: 4
                color: "#fbf8f1"
                border.color: "#211d2a"
                border.width: 2
            }

            Rectangle {
                x: -speech.x - 2
                y: speech.height - 2
                width: 4
                height: 3
                color: "#fbf8f1"
            }
        }
    }
}
