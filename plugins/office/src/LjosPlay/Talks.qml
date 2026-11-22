import QtQuick

// Talks: the speaker walks up, says its line, and the listener replies.
QtObject {
    id: talks

    property var world
    property real sayFor: 5000
    property real replyFor: 2200
    property real giveUpAfter: 25000

    // Whether someone other than `speaker` is talking to this actor.
    function listening(actor, speaker) {
        const other = actor?.heldBy ? world.actors[actor.heldBy] : null;
        return !!other && other !== speaker && other.talk?.to === actor.key;
    }

    // Whether a speaker who came up keeps it here. Only on a tile that is free.
    function held(actor) {
        const speaker = actor.heldBy ? world.actors[actor.heldBy] : null;
        return !!speaker && !!speaker.talk && speaker.talk.to === actor.key && speaker.talk.met && world.free({ x: actor.tx, y: actor.ty }, actor);
    }

    function towards(a, b) {
        const dx = b.tx - a.tx, dy = b.ty - a.ty;
        if (Math.abs(dx) >= Math.abs(dy) && dx !== 0)
            return dx < 0 ? 1 : 2;
        return dy < 0 ? 3 : 0;
    }

    // Starts the first talk whose listener is in and not in another talk.
    // Two who talk to each other take turns.
    function begin(actor) {
        if (listening(actor))
            return;
        const next = actor.queue.findIndex(t => {
            const other = world.actors[t.to];
            return !(other?.tx < 0) && !other?.talk && !listening(other, actor);
        });
        if (next < 0)
            return;
        const talk = actor.queue.splice(next, 1)[0];
        const other = world.actors[talk.to];
        if (!other)
            return;
        other.heldBy = actor.key;
        actor.talk = {
            id: talk.id,
            to: talk.to,
            text: spoken(talk.text),
            kind: talk.kind,
            phase: "go",
            deadline: world.now + giveUpAfter,
            target: -1,
            until: 0,
            met: false
        };
        world.walking = true;
    }

    function spoken(text) {
        return (text ?? "").replace(/\s+/g, " ").slice(0, 120);
    }

    function end(actor) {
        const other = actor.talk ? world.actors[actor.talk.to] : null;
        if (other && other.heldBy === actor.key) {
            other.face = -1;
            other.heldBy = "";
            world.letGo(other);
        }
        actor.talk = null;
        actor.bubble = "";
        actor.plan = "";
        actor.decide(true);
    }

    function step(actor) {
        const t = actor.talk;
        const other = world.actors[t.to];
        if (!other || world.now > t.deadline && t.phase === "go") {
            end(actor);
            return;
        }
        const W = world.columns;
        const near = Math.abs(actor.tx - other.tx) + Math.abs(actor.ty - other.ty) === 1;
        if (t.phase === "go") {
            if (near)
                t.met = true;
            // It starts when both stand side by side, each on a tile of its own.
            const atSide = actor.next < 0 && actor.goal?.kind === "talk" && actor.tx === actor.goal.x && actor.ty === actor.goal.y;
            if (near && atSide && other.next < 0 && world.free({ x: other.tx, y: other.ty }, other)) {
                world.holdHere(other);
                t.phase = "say";
                t.until = world.now + sayFor;
                actor.path = [];
                actor.bubble = t.text;
                actor.bubbleUntil = t.until;
                return;
            }
            if (near && atSide)
                return;
            const there = other.ty * W + other.tx;
            if (t.target !== there || actor.path.length === 0 && actor.next < 0) {
                t.target = there;
                toSide(actor, other);
            }
            return;
        }
        if (!near) {
            end(actor);
            return;
        }
        if (!carryOn(actor, other))
            return;
        actor.dir = towards(actor, other);
        other.face = towards(other, actor);
        if (t.phase === "say" && world.now >= t.until) {
            t.phase = "reply";
            t.until = world.now + replyFor;
            actor.bubble = "";
            other.bubble = other.reply(t);
            other.bubbleUntil = t.until;
        } else if (t.phase === "reply" && world.now >= t.until) {
            other.bubble = "";
            end(actor);
        }
    }

    // To a free side of `other`: beside it first, so neither bubble covers
    // the other, or with `nearest` the nearest.
    function toSide(actor, other, nearest) {
        const sides = [[-1, 0], [1, 0], [0, -1], [0, 1]].map(([dx, dy]) => ({
                    x: other.tx + dx,
                    y: other.ty + dy
                })).filter(s => world.walkable(s.x, s.y) && world.free(s, actor));
        if (!sides.length)
            return false;
        const inside = (a, m, b) => Math.min(a, b) < m && m < Math.max(a, b);
        const walk = s => {
            const round = s.y === actor.ty && other.ty === actor.ty && inside(actor.tx, other.tx, s.x) || s.x === actor.tx && other.tx === actor.tx && inside(actor.ty, other.ty, s.y);
            return Math.abs(s.x - actor.tx) + Math.abs(s.y - actor.ty) + (round ? 2 : 0);
        };
        const beside = (a, b) => (b.y === other.ty) - (a.y === other.ty);
        sides.sort((a, b) => nearest ? walk(a) - walk(b) || beside(a, b) : beside(a, b) || walk(a) - walk(b));
        actor.goal = Object.assign({ face: 0, offY: 0, pose: "talk", kind: "talk" }, sides[0]);
        world.claim(actor, actor.goal);
        actor.route();
        return true;
    }

    // Both keep their tiles until it ends, claimed again if lost. A speaker
    // who lost its side says it again from another, or the talk ends.
    function carryOn(actor, other) {
        const W = world.columns;
        const t = actor.talk;
        const side = { x: actor.tx, y: actor.ty };
        if (other.hold !== other.ty * W + other.tx) {
            world.letGo(other);
            world.holdHere(other);
            if (other.hold < 0) {
                end(actor);
                return false;
            }
        }
        if (actor.claim === side.y * W + side.x)
            return true;
        if (world.free(side, actor)) {
            actor.goal = Object.assign({ face: 0, offY: 0, pose: "talk", kind: "talk" }, side);
            world.claim(actor, actor.goal);
            return true;
        }
        if (!toSide(actor, other, true)) {
            end(actor);
            return false;
        }
        actor.bubble = "";
        other.bubble = "";
        t.phase = "go";
        t.target = other.ty * W + other.tx;
        t.deadline = world.now + giveUpAfter;
        return false;
    }
}
