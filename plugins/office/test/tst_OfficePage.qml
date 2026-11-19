// Run from a hal-c2 checkout:
//   ljos test --import apps/desktop-qt/tests/imports --import apps/desktop-qt/qml \
//     plugins/office/test/tst_OfficePage.qml
// and with Qt, with QT_QPA_PLATFORM=offscreen:
//   qmltestrunner -import apps/desktop-qt/tests/imports -import apps/desktop-qt/qml \
//     -input plugins/office/test/tst_OfficePage.qml
import QtQuick
import QtTest

// A TestCase is never visible, so what it clicks lives beside it.
Item {
    id: test

    width: 1200
    height: 760

    function person(id, title, state, activity, parentId) {
        return {
            id: id,
            title: title,
            projectId: "p-api",
            project: "api",
            parentId: parentId ?? null,
            provider: "claudeAgent",
            model: "claude-opus-5-5",
            state: state,
            activity: activity ?? null,
            question: state === "asking" ? {
                kind: "approval",
                since: "2026-11-18T21:00:00Z"
            } : null,
            since: "2026-11-18T21:00:00Z"
        };
    }

    function many(n, prefix, state, activity, parentId) {
        const people = [];
        for (let i = 0; i < n; i++)
            people.push(person(prefix + i, prefix + " " + i, state, activity, parentId));
        return people;
    }

    // The plugin object a page gets, with the MC part faked: `publish` is what
    // the MC part publishes, and each thread opened is recorded.
    QtObject {
        id: plugin

        property var environments: ["local"]
        property var watchers: ({})
        property var opened: []

        function watch(topic, callback, environment) {
            watchers[environment + "/" + topic] = callback;
            return environment + "/" + topic;
        }

        function unwatch(handle) {
        }

        function call(method, input, callback, environment) {
            callback(null, null);
        }

        function openThread(threadId, environment) {
            opened = opened.concat([environment + "/" + threadId]);
        }

        function publish(people, talks) {
            watchers["local/office"]({
                people: people,
                talks: talks ?? []
            });
        }
    }

    Loader {
        id: loader

        width: test.width
        height: test.height
    }

    TestCase {
        name: "OfficePage"
        when: windowShown

        readonly property var page: loader.item

        function find(name) {
            return findChild(loader.item, name);
        }

        function open() {
            loader.source = "";
            loader.setSource(Qt.resolvedUrl("../ui/OfficePage.qml"), {
                plugin: plugin
            });
            tryVerify(() => loader.status === Loader.Ready && plugin.watchers["local/office"] !== undefined);
            // The office's own clock holds still; each test runs it with advance().
            loader.item.applicationActive = false;
        }

        function init() {
            loader.width = Qt.binding(() => test.width);
            loader.height = Qt.binding(() => test.height);
            stood = {};
            plugin.environments = ["local"];
            plugin.watchers = {};
            plugin.opened = [];
            open();
        }

        function actor(id) {
            return page.actors[id];
        }

        // Runs the office until `done` holds, or fails after `limit` ticks.
        function runUntil(done, limit, message) {
            for (let i = 0; i < (limit ?? 1500); i++) {
                if (done())
                    return;
                page.advance(1);
            }
            verify(done(), message ?? "the office never got there");
        }

        function arrived(a) {
            return a.goal && a.tx === a.goal.x && a.ty === a.goal.y && a.next < 0 && a.path.length === 0;
        }

        // The tiles each person held when the floor was last checked.
        property var stood: ({})

        // Nobody stands on a wall or furniture or off the floor, a seat is only
        // stepped onto as where a person is going (a step already begun ends
        // there, and the person leaves again), a step goes
        // to a tile next to the person, each person holds the tiles it stands
        // on and steps to, and no two people hold the same tile.
        function checkFloor() {
            const w = page.world;
            const held = {};
            const stood = {};
            for (const id of Object.keys(page.actors)) {
                const a = page.actors[id];
                verify(a.tx >= 0 && a.ty >= 0 && a.tx < w.cols && a.ty < w.rows, id + " is off the floor at " + a.tx + "," + a.ty);
                const here = a.ty * w.cols + a.tx;
                const tiles = [here];
                if (a.next >= 0) {
                    const nx = a.next % w.cols, ny = (a.next - nx) / w.cols;
                    compare(Math.abs(nx - a.tx) + Math.abs(ny - a.ty), 1, id + " steps from " + a.tx + "," + a.ty + " to " + nx + "," + ny);
                    tiles.push(a.next);
                }
                for (const t of tiles)
                    compare(page.occupied[t], id, id + " holds the tile at " + t % w.cols + "," + Math.floor(t / w.cols));
                for (const t of tiles) {
                    const x = t % w.cols, y = (t - x) / w.cols;
                    const cell = w.grid[t];
                    const goal = a.goal && a.goal.x === x && a.goal.y === y;
                    const stayed = (this.stood[id] ?? []).includes(t);
                    verify(cell === 0 || cell === 2 && (goal || stayed), id + " stands on furniture at " + x + "," + y);
                    verify(held[t] === undefined, id + " and " + held[t] + " overlap at " + x + "," + y);
                    held[t] = id;
                }
                stood[id] = tiles;
            }
            const taken = page.occupied.filter(owner => owner).length;
            compare(taken, Object.keys(held).length, "only people's tiles are held");
            this.stood = stood;
        }

        // Runs the office n ticks, checking the floor after each.
        function walk(n) {
            for (let i = 0; i < n; i++) {
                page.advance(1);
                checkFloor();
            }
        }

        function test_every_person_looks_like_someone_of_their_own() {
            const people = many(12, "t", "working", "typing");
            plugin.publish(people);
            const looks = people.map(p => JSON.stringify(actor(p.id).look));
            compare(new Set(looks).size, 12);
            const genders = new Set(people.map(p => actor(p.id).look.gender));
            verify(genders.has("woman") && genders.has("man"), "a mix of women and men");
            for (const p of people)
                verify(!actor(p.id).look.pet, p.id + " is not a worker, so it is a person");

            // The page reopened draws everyone as before.
            open();
            plugin.publish(people);
            compare(people.map(p => JSON.stringify(actor(p.id).look)), looks);
        }

        // A host that makes the page without giving it a size still shows the
        // office, with the zoom buttons beside the summary, not over it.
        function test_a_page_given_no_size_shows_the_office() {
            const made = createTemporaryObject(Qt.createComponent(Qt.resolvedUrl("../ui/OfficePage.qml")), test, {
                plugin: plugin
            });
            plugin.publish(many(3, "t", "working", "typing"));
            tryVerify(() => made.worldCols > 0);
            wait(50);
            const summary = findChild(made, "officeSummary");
            const scroller = findChild(made, "officeScroller");
            const row = summary.parent;
            let needed = summary.implicitWidth;
            let buttons = 0;
            for (let i = 0; i < row.children.length; i++) {
                const button = row.children[i];
                if (button === summary || !button.visible)
                    continue;
                needed += row.spacing + button.width;
                buttons++;
            }
            compare(buttons, 3);
            verify(row.width >= needed, "the summary and the zoom buttons fit side by side");
            verify(scroller.width >= made.worldCols * 16 && scroller.height > 0, "the office has room to show");
        }

        function test_some_workers_are_cats_and_dogs() {
            const lead = person("lead", "Lead", "working", "typing");
            const workers = many(20, "w", "working", "typing", "lead");
            plugin.publish([lead].concat(workers));
            const species = workers.map(w => actor(w.id).look.species);
            verify(species.includes("cat"), "some workers are cats");
            verify(species.includes("dog"), "some workers are dogs");
            verify(species.includes("human"), "most workers are people");
            compare(actor("lead").look.species, "human");
        }

        function test_workers_sit_with_the_thread_that_delegated_to_them() {
            const people = [person("lead", "Lead", "working", "typing")].concat(many(3, "w", "working", "typing", "lead"), many(6, "o", "working", "typing"));
            plugin.publish(people);
            const podOf = id => page.world.pods.findIndex(pod => pod.members.includes(id));
            const pod = podOf("lead");
            verify(pod >= 0);
            for (const w of ["w0", "w1", "w2"]) {
                compare(podOf(w), pod);
                verify(page.world.pods[pod].seats.includes(page.world.seatOf[w]), w + " has a desk in the lead's pod");
            }
        }

        function test_people_walk_around_furniture_and_never_through_each_other() {
            const activities = ["typing", "planning", "reading", "testing"];
            const people = [];
            for (let i = 0; i < 16; i++)
                people.push(person("t" + i, "Thread " + i, "working", activities[i % 4]));
            plugin.publish(people);
            checkFloor();
            // Everyone changes what they do, so they cross the office.
            for (let round = 0; round < 3; round++) {
                for (let i = 0; i < 16; i++)
                    people[i] = person("t" + i, "Thread " + i, i % 3 === round ? "waiting" : "working", activities[(i + round + 1) % 4]);
                plugin.publish(people.slice());
                walk(300);
            }
        }

        function test_desks_that_change_hands_are_walked_to() {
            plugin.publish([person("a", "A", "working", "typing"), person("b", "B", "working", "typing")]);
            const signature = page.world.signature;
            const before = page.world.seatOf["b"];
            // A leaves and C comes in: B takes A's desk and C takes B's.
            plugin.publish([person("b", "B", "working", "typing"), person("c", "C", "working", "typing")]);
            compare(page.world.signature, signature, "the same desks");
            verify(page.world.seatOf["b"] !== before, "B was given another desk");
            runUntil(() => arrived(actor("b")) && arrived(actor("c")), 1500, "both reach their desks");
            for (const id of ["b", "c"]) {
                const seat = page.world.seatOf[id];
                compare([actor(id).tx, actor(id).ty], [seat.x, seat.y], id + " sits at its own desk");
            }
        }

        function test_people_stay_on_the_floor_when_the_office_shrinks() {
            const a = [person("a", "A", "working", "typing")].concat(many(19, "aw", "working", "typing", "a"));
            const b = [person("b", "B", "working", "typing")].concat(many(19, "bw", "working", "typing", "b"));
            plugin.publish(a.concat(b));
            const resting = a.map(p => person(p.id, p.title, "waiting", null, p.parentId));
            const byId = {};
            for (const p of resting)
                byId[p.id] = p;
            const narrow = page.buildWorld(page.podsFor(page.teamsOf(resting.map(p => p.id), byId))).cols;
            verify(narrow < page.world.cols, "one team needs a narrower office");
            plugin.publish(resting.concat(b));
            // Someone in the break room stands past where the narrower office
            // ends, by more than a tile so its old place there wraps onto floor.
            runUntil(() => resting.some(p => actor(p.id).tx > narrow), 3000, "a person reaches the far side of the break room");
            plugin.publish(resting);
            compare(page.world.cols, narrow);
            checkFloor();
            walk(50);
        }

        function test_a_break_lasts_from_when_the_person_gets_there() {
            const people = many(20, "t", "working", "typing");
            plugin.publish(people);
            const resting = people.slice(0, 8).map(p => person(p.id, p.title, "waiting"));
            plugin.publish(resting.concat(people.slice(8)));
            const first = {}, since = {};
            runUntil(() => {
                let done = 0;
                for (const p of resting) {
                    const a = actor(p.id);
                    first[p.id] = first[p.id] ?? a.goal;
                    if (since[p.id] === undefined) {
                        if (arrived(a))
                            since[p.id] = page.now;
                    } else if (page.now - since[p.id] >= 3000) {
                        done++;
                    } else {
                        verify(a.goal === first[p.id], p.id + " left its break spot " + (page.now - since[p.id]) + " ms after getting there");
                    }
                }
                return done === resting.length;
            }, 3000, "everyone gets a break");
        }

        function test_a_person_turned_around_mid_step_walks_back_tile_by_tile() {
            plugin.publish([person("lead", "Lead", "working", "typing")]);
            const desk = page.world.seatOf["lead"];
            plugin.publish([person("lead", "Lead", "waiting")]);
            runUntil(() => actor("lead").next >= 0 && Math.abs(actor("lead").tx - desk.x) + Math.abs(actor("lead").ty - desk.y) >= 3, 1500, "the person walks off");
            plugin.publish([person("lead", "Lead", "working", "typing")]);
            for (let i = 0; i < 400 && !arrived(actor("lead")); i++)
                walk(1);
            compare([actor("lead").tx, actor("lead").ty], [desk.x, desk.y]);
        }

        // A person standing still in the way is waited for: the person behind
        // it once stepped aside and back every second, pacing on the spot.
        function test_a_person_blocked_by_someone_standing_still_waits() {
            plugin.publish([person("a", "A", "working", "typing"), person("b", "B", "working", "typing")]);
            const a = actor("a"), b = actor("b");
            // A heads for B's desk, which B never leaves.
            page.setGoal(a, {
                x: b.tx,
                y: b.ty,
                face: 0,
                offY: 0,
                pose: "type",
                kind: "desk",
                seat: true
            });
            runUntil(() => a.blocked > 0, 1500, "A walks up to B");
            const spot = [a.tx, a.ty];
            for (let i = 0; i < 200; i++) {
                walk(1);
                compare([a.tx, a.ty, a.next], spot.concat([-1]), "A waits where it is");
            }
        }

        // Where a row of open floor with open rows above and below it starts.
        function openFloor(length) {
            const w = page.world;
            for (let y = 1; y < w.rows - 1; y++) {
                for (let x = 0; x + length <= w.cols; x++) {
                    let open = true;
                    for (let dx = 0; dx < length && open; dx++) {
                        for (let dy = -1; dy <= 1; dy++)
                            open = open && page.walkable(x + dx, y + dy) && !page.occupied[(y + dy) * w.cols + x + dx];
                    }
                    if (open)
                        return [x, y];
                }
            }
            fail("the office has open floor");
        }

        // Stands A and B side by side and sends each to its own tile of the row.
        function meet(left, row, aTo, bTo) {
            const w = page.world;
            const a = actor("a"), b = actor("b");
            for (const who of [a, b]) {
                page.occupied[who.ty * w.cols + who.tx] = "";
                who.goal = null;
                who.path = [];
            }
            page.place(a, left, row, true);
            page.place(b, left + 1, row, true);
            const goal = x => ({
                    x: x,
                    y: row,
                    face: 0,
                    offY: 0,
                    pose: "stand",
                    kind: "floor"
                });
            page.setGoal(a, goal(aTo));
            page.setGoal(b, goal(bTo));
            for (let i = 0; i < 600 && !(arrived(a) && arrived(b)); i++)
                walk(1);
            compare([a.tx, a.ty, b.tx, b.ty], [aTo, row, bTo, row], "both get where they are going");
        }

        // Two people walking into each other once both stepped around the same
        // way, met again, and stepped back, over and over.
        function test_two_people_walking_into_each_other_get_past() {
            plugin.publish([person("a", "A", "working", "typing"), person("b", "B", "working", "typing")]);
            const [left, row] = openFloor(8);
            meet(left + 3, row, left + 7, left);
        }

        // Two people headed for each other's tile cannot go around: one steps
        // aside to let the other through.
        function test_two_people_swapping_places_get_there() {
            plugin.publish([person("a", "A", "working", "typing"), person("b", "B", "working", "typing")]);
            const [left, row] = openFloor(4);
            meet(left + 1, row, left + 2, left + 1);
        }

        function test_what_a_person_does_follows_its_agent() {
            const lead = person("lead", "Lead", "working", "typing");
            plugin.publish([lead]);
            runUntil(() => arrived(actor("lead")));
            compare(actor("lead").goal.kind, "desk");
            page.advance(7);
            verify([page.frame.type1, page.frame.type2].includes(actor("lead").frame), "typing at the computer");

            plugin.publish([person("lead", "Lead", "working", "planning")]);
            compare(actor("lead").goal.kind, "board");
            runUntil(() => arrived(actor("lead")));
            verify([page.frame.raise1, page.frame.raise2].includes(actor("lead").frame), "drawing on the whiteboard");

            plugin.publish([person("lead", "Lead", "working", "reading")]);
            compare(actor("lead").goal.kind, "shelf");
            runUntil(() => arrived(actor("lead")));
            compare(actor("lead").frame, page.frame.book);
        }

        function test_waiting_people_take_a_break_and_come_back() {
            plugin.publish([person("lead", "Lead", "working", "typing")]);
            runUntil(() => arrived(actor("lead")));
            const desk = [actor("lead").tx, actor("lead").ty];

            plugin.publish([person("lead", "Lead", "waiting")]);
            verify(actor("lead").goal.area === "break" || actor("lead").goal.kind === "floor");
            runUntil(() => arrived(actor("lead")) && actor("lead").tx > page.world.xd, 2000, "the person reaches the break room");

            plugin.publish([person("lead", "Lead", "working", "typing")]);
            runUntil(() => arrived(actor("lead")) && actor("lead").goal.kind === "desk", 2000, "the person walks back to its desk");
            compare([actor("lead").tx, actor("lead").ty], desk);
        }

        function test_two_agents_that_talk_walk_up_to_each_other() {
            const people = [person("lead", "Lead", "working", "typing"), person("rev", "Reviewer", "working", "typing")].concat(many(6, "o", "working", "typing"));
            plugin.publish(people);
            runUntil(() => arrived(actor("lead")) && arrived(actor("rev")));
            plugin.publish(people, [
                {
                    id: "talk-1",
                    from: "lead",
                    to: "rev",
                    kind: "message",
                    text: "Please look at the diff",
                    at: new Date().toISOString()
                }
            ]);
            runUntil(() => actor("lead").talk?.phase === "say", 2000, "the speaker walks up");
            page.advance(1);
            const a = actor("lead"), b = actor("rev");
            compare(Math.abs(a.tx - b.tx) + Math.abs(a.ty - b.ty), 1);
            compare(a.dir, page.dirTowards(a, b));
            compare(b.face, page.dirTowards(b, a));
            const bubble = find("officeBubble:lead");
            verify(bubble.visible);
            compare(page.overlays["lead"].bubble, "Please look at the diff");

            runUntil(() => actor("lead").talk === null, 400, "the talk ends");
            verify(!bubble.visible);
            runUntil(() => arrived(actor("lead")) && actor("lead").goal.kind === "desk", 2000, "the speaker goes back to work");
        }

        function test_a_person_spoken_to_stops_to_listen_and_then_goes_on() {
            // Lead and C get the desks side by side.
            plugin.publish([person("lead", "Lead", "working", "typing"), person("b", "B", "working", "typing"), person("c", "C", "working", "typing")]);
            compare(Math.abs(actor("lead").tx - actor("c").tx) + Math.abs(actor("lead").ty - actor("c").ty), 1);
            // C heads for a break just as the lead speaks to it.
            plugin.publish([person("lead", "Lead", "working", "typing"), person("b", "B", "working", "typing"), person("c", "C", "waiting")], [
                {
                    id: "talk-1",
                    from: "lead",
                    to: "c",
                    kind: "message",
                    text: "Got a minute?",
                    at: new Date().toISOString()
                }
            ]);
            runUntil(() => actor("lead").talk?.phase === "say", 2000, "the talk starts");
            const a = actor("lead"), c = actor("c");
            const spot = [c.tx, c.ty];
            while (a.talk) {
                compare(c.next, -1, "C stands still while spoken to");
                compare([c.tx, c.ty], spot);
                compare(Math.abs(a.tx - c.tx) + Math.abs(a.ty - c.ty), 1, "the two stay together");
                page.advance(1);
            }
            verify(c.path.length > 0 || c.next >= 0, "C still knows where it was going");
            runUntil(() => arrived(c) && c.tx > page.world.xd, 2000, "C goes on to the break room");
        }

        // The office fills the view by its width or its height, whichever runs
        // out first, and the zoom buttons step it a little at a time.
        function test_the_office_fits_the_view_and_zooms_in_small_steps() {
            plugin.publish(many(9, "t", "working", "typing"));
            tryVerify(() => page.worldCols > 0);
            const scroller = find("officeScroller");
            const stage = find("officeStage");
            verify(stage.width <= scroller.width && stage.height <= scroller.height, "the whole office shows");
            verify(scroller.width - stage.width <= 8 || scroller.height - stage.height <= 8, "it fills one side of the view");
            const fitted = page.pixelScale;
            page.zoomBy(1.25);
            verify(page.pixelScale > fitted && page.pixelScale < fitted * 1.5, "one step zooms in by less than half again");
            page.zoom = 1;
            compare(page.pixelScale, fitted);
        }

        // A large view fits the office at a scale where zoomed steps snap to
        // whole device pixels; the fit itself does not snap, so the office
        // still fills one side of the view.
        function test_a_large_fit_fills_the_view() {
            loader.width = 2600;
            loader.height = 1600;
            plugin.publish(many(1, "t", "working", "typing"));
            tryVerify(() => page.worldCols > 0 && page.fitScale * page.devicePixelRatio >= 4, 1000, "the office fits at 4 device pixels or more");
            const scroller = find("officeScroller");
            const stage = find("officeStage");
            verify(stage.width <= scroller.width + 0.5 && stage.height <= scroller.height + 0.5, "the whole office shows");
            verify(scroller.width - stage.width <= 8.5 || scroller.height - stage.height <= 8.5, "it fills one side of the view");
        }

        // Where zoom snaps to whole device pixels, zooming in and back out
        // returns to the same scale.
        function test_zooming_in_and_out_returns_to_the_same_scale() {
            plugin.publish(many(1, "t", "working", "typing"));
            tryVerify(() => page.worldCols > 0);
            page.zoom = 4 / page.devicePixelRatio / page.fitScale;
            for (let i = 0; i < 6 && page.pixelScale < 7.999; i++) {
                const before = page.pixelScale;
                page.zoomBy(1.25);
                page.zoomBy(1 / 1.25);
                fuzzyCompare(page.pixelScale, before, 1e-9, "out undoes in");
                page.zoomBy(1.25);
            }
        }

        // At a zoom between whole pixels the art is drawn at a whole number of
        // device pixels per art pixel and shrunk smoothly, so no art pixel is
        // drawn wider than another; at a whole zoom it is drawn as it is.
        function test_art_at_a_fractional_zoom_keeps_its_pixels_even() {
            plugin.publish(many(3, "t", "working", "typing"));
            tryVerify(() => page.worldCols > 0);
            const art = find("officeArt");
            const stage = find("officeStage");
            const ratio = page.devicePixelRatio;
            page.zoom = 3.5 / ratio / page.fitScale;
            const devicePixels = page.drawScale * ratio;
            fuzzyCompare(devicePixels, Math.round(devicePixels), 1e-9, "each art pixel is a whole number of device pixels");
            verify(page.drawScale >= page.pixelScale);
            verify(art.layer.enabled && art.layer.smooth, "the art is shrunk smoothly");
            fuzzyCompare(art.width * art.scale, stage.width, 1e-6);
            page.zoom = 3 / ratio / page.fitScale;
            verify(!art.layer.enabled, "a whole zoom draws the art directly");
            compare(art.scale, 1);
        }

        // Zoomed far in, a step of one device pixel is fine enough, so the
        // scale snaps to whole device pixels and no layer the size of the
        // whole zoomed office is drawn.
        function test_zoomed_in_far_the_art_is_drawn_directly() {
            plugin.publish(many(20, "t", "working", "typing"));
            tryVerify(() => page.worldCols > 0);
            const art = find("officeArt");
            let steps = 0;
            while (page.pixelScale < 7.999 && steps < 40) {
                const before = page.pixelScale;
                page.zoomBy(1.25);
                verify(page.pixelScale > before, "each step zooms in");
                if (art.layer.enabled)
                    verify(page.drawScale * page.devicePixelRatio <= 4, "a layer is drawn only at a small scale");
                steps++;
            }
            fuzzyCompare(page.pixelScale, 8, 1e-9);
            verify(!art.layer.enabled, "the most zoomed in office is drawn directly");
            while (page.pixelScale > 1.001 && steps < 80) {
                const before = page.pixelScale;
                page.zoomBy(1 / 1.25);
                verify(page.pixelScale < before, "each step zooms out");
                steps++;
            }
        }

        // A view smaller than the office still fits all of it, and a zoom step
        // after the view changes moves the scale from what is shown.
        function test_a_small_view_fits_the_office_and_zoom_steps_from_what_shows() {
            plugin.publish(many(3, "t", "working", "typing"));
            tryVerify(() => page.worldCols > 0);
            const scroller = find("officeScroller");
            const stage = find("officeStage");
            while (page.pixelScale > page.minScale + 0.001)
                page.zoomBy(1 / 1.25);
            loader.height = 200;
            tryVerify(() => page.fitScale < 1, 1000, "the office is taller than the view");
            verify(stage.width <= scroller.width + 0.5 && stage.height <= scroller.height + 0.5, "the whole office shows when zoomed out");
            const shown = page.pixelScale;
            page.zoomBy(1.25);
            verify(page.pixelScale > shown, "the first step after the view shrank zooms in");
            page.zoom = 1;
            verify(stage.width <= scroller.width + 0.5 && stage.height <= scroller.height + 0.5, "the whole office shows at Fit");
        }

        function test_a_person_tabbed_to_is_scrolled_into_view() {
            plugin.publish(many(20, "t", "working", "typing"));
            page.zoom = 8 / page.fitScale;
            const scroller = find("officeScroller");
            const far = Object.values(page.actors).reduce((m, a) => a.tx + a.ty > m.tx + m.ty ? a : m);
            const hit = find("officePerson:" + far.id);
            const inView = () => {
                const r = hit.mapToItem(scroller, 0, 0, hit.width, hit.height);
                return r.x >= 0 && r.y >= 0 && r.x + r.width <= scroller.width && r.y + r.height <= scroller.height;
            };
            verify(!inView(), "the person starts out of view");
            hit.forceActiveFocus();
            verify(inView(), "the person is scrolled into view");
            compare(page.hovered, far.id);
        }

        function test_markup_in_a_title_shows_as_typed() {
            plugin.publish([person("t", "<i></i>", "working", "testing")]);
            page.hovered = "t";
            tryVerify(() => find("officeCard").visible);
            verify(find("officeCardTitle").implicitWidth > 0, "the title is shown as text");
        }

        function test_a_machine_that_leaves_takes_its_office_with_it() {
            plugin.environments = ["local", "lab"];
            plugin.watchers["lab/office"]({
                people: [person("x", "X", "working", "typing")],
                talks: []
            });
            verify(page.byEnvironment["lab"] !== undefined);
            plugin.environments = ["local"];
            compare(page.byEnvironment["lab"], undefined);
            plugin.environments = ["local", "lab"];
            page.environment = "lab";
            compare(page.office, null, "nothing stale shows before the new watch delivers");
        }

        function test_an_asking_person_shows_a_question_and_opens_its_thread() {
            plugin.publish([person("ask", "Fix the parser", "asking"), person("busy", "Busy", "working", "typing")]);
            runUntil(() => arrived(actor("ask")));
            compare(page.iconOf(actor("ask")), "ask");
            verify(find("officeIcon:ask").visible);
            verify(!find("officeIcon:busy").visible);
            waitForRendering(loader.item);
            mouseClick(find("officePerson:ask"));
            compare(plugin.opened, ["local/ask"]);
        }

        function test_hovering_a_person_names_it_and_what_it_does() {
            plugin.publish([person("t", "Fix the parser", "working", "testing")]);
            runUntil(() => arrived(actor("t")));
            waitForRendering(loader.item);
            mouseMove(find("officePerson:t"));
            tryVerify(() => find("officeCard").visible);
            compare(find("officeCardTitle").text, "Fix the parser");
            compare(find("officeCardProject").text.indexOf("api") >= 0, true);
            compare(find("officeCardAgent").text, "claudeAgent · claude-opus-5-5");
            verify(find("officeCardState").text.toLowerCase().indexOf("test") >= 0, find("officeCardState").text);
        }

        function test_the_keyboard_reaches_a_person() {
            plugin.publish([person("ask", "Fix the parser", "asking")]);
            runUntil(() => arrived(actor("ask")));
            const hit = find("officePerson:ask");
            hit.forceActiveFocus();
            compare(page.hovered, "ask");
            keyClick(Qt.Key_Return);
            compare(plugin.opened, ["local/ask"]);
        }

        function test_the_office_grows_with_the_people_in_it() {
            plugin.publish(many(4, "t", "working", "typing"));
            const small = page.deskCount;
            verify(small >= 4);
            plugin.publish(many(20, "t", "working", "typing"));
            verify(page.deskCount >= 20, "a desk for each of 20 threads, has " + page.deskCount);
            for (let i = 0; i < 20; i++)
                verify(page.world.seatOf["t" + i] !== undefined, "t" + i + " has a desk");
            checkFloor();
        }

        function test_the_office_holds_still_while_it_is_not_shown() {
            plugin.publish(many(2, "t", "working", "typing"));
            page.applicationActive = true;
            verify(page.animating);
            page.visible = false;
            verify(!page.animating);
            page.visible = true;
            verify(page.animating);
            page.applicationActive = false;
            verify(!page.animating);
        }
    }
}
