// Run from a hal-c2 checkout:
//   ljos test --import apps/desktop-qt/tests/imports --import apps/desktop-qt/qml \
//     plugins/office/test/tst_OfficePage.qml
// and with Qt 6, with QT_QPA_PLATFORM=offscreen (a bare qmltestrunner may be Qt 5's,
// which prints nothing and exits 1):
//   "$(qmake6 -query QT_INSTALL_BINS)/qmltestrunner" -import apps/desktop-qt/tests/imports -import apps/desktop-qt/qml \
//     -input plugins/office/test/tst_OfficePage.qml
import QtQuick
import QtTest
import HalC2.Shell

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

    // A thread the code-review plugin started, or one of its workers.
    function reviewer(id, title, parentId) {
        return Object.assign(person(id, title, "working", "typing", parentId), {
            kind: "reviewer"
        });
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
            loader.item.inSight = false;
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

        function cleanup() {
            loader.source = "";
            // A test that minimized the window and failed mid-way leaves it
            // minimized for every test after it.
            if (test.Window.window && test.Window.window.visibility === Window.Minimized)
                test.Window.window.showNormal();
            Shell.state = Object.assign({}, Shell.state, {
                projectIcons: undefined
            });
        }

        function actor(id) {
            return page.game.actors[id];
        }

        function corner() {
            return page.world.pods.findIndex(pod => pod.review);
        }

        // A Repeater's items by the key of what each shows.
        function viewsIn(repeater) {
            const byKey = {};
            for (let i = 0; i < repeater.count; i++) {
                const item = repeater.itemAt(i);
                if (item)
                    byKey[item.modelData.key] = item;
            }
            return byKey;
        }

        function markOf(id) {
            return viewsIn(page.markViews)["mark:" + page.world.seatOf[id].index];
        }

        function icons(map) {
            Shell.state = Object.assign({}, Shell.state, {
                projectIcons: map
            });
        }

        // Runs the office until `done` holds, or fails after `limit` ticks.
        function runUntil(done, limit, message) {
            for (let i = 0; i < (limit ?? 1500); i++) {
                if (done())
                    return;
                page.game.advance(1);
            }
            verify(done(), message ?? "the office never got there");
        }

        function arrived(a) {
            return a.goal && a.tx === a.goal.x && a.ty === a.goal.y && a.next < 0 && a.path.length === 0;
        }

        // The tiles each person held when the floor was last checked, and the
        // width and break-room wall of the floor then.
        property var stood: ({})
        property var stoodOn: null

        // Nobody, people or movers, stands on a wall or furniture or off the
        // floor, a seat is only stepped onto as where a person is going (a
        // step already begun ends there, and the person leaves again), and a
        // step goes to a tile next to the person. People walk through each
        // other, but each claims the tile it stops at, and no two stop on one
        // tile. A carried desk is drawn within its mover's figure.
        function checkFloor() {
            const w = page.world;
            // A floor built again at another width keeps every tile west of
            // the break room's wall and shifts the rest (see rearrange()).
            const [cols, xd] = this.stoodOn ?? [w.cols, w.xd];
            const moved = t => {
                const x = t % cols, y = (t - x) / cols;
                return y * w.cols + (x >= xd ? x + w.xd - xd : x);
            };
            const stopped = {};
            const stood = {};
            const everyone = Object.assign({}, page.game.actors, page.crew.members);
            for (const id of Object.keys(everyone)) {
                const a = everyone[id];
                if (page.outside.includes(id))
                    continue;
                verify(a.tx >= 0 && a.ty >= 0 && a.tx < w.cols && a.ty < w.rows, id + " is off the floor at " + a.tx + "," + a.ty);
                const here = a.ty * w.cols + a.tx;
                const tiles = [here];
                if (a.next >= 0) {
                    const nx = a.next % w.cols, ny = (a.next - nx) / w.cols;
                    compare(Math.abs(nx - a.tx) + Math.abs(ny - a.ty), 1, id + " steps from " + a.tx + "," + a.ty + " to " + nx + "," + ny);
                    tiles.push(a.next);
                }
                for (const t of tiles) {
                    const x = t % w.cols, y = (t - x) / w.cols;
                    const cell = page.game.plan().grid[t];
                    const goal = a.goal && a.goal.x === x && a.goal.y === y;
                    const stayed = (this.stood[id] ?? []).map(moved).includes(t);
                    verify(cell === 0 || cell === 2 && (goal || stayed), id + " stands on furniture at " + x + "," + y);
                }
                if (a.next < 0 && a.path.length === 0) {
                    verify(stopped[here] === undefined, id + " and " + stopped[here] + " stop on one tile at " + a.tx + "," + a.ty);
                    stopped[here] = id;
                }
                if (page.game.actors[id] && a.goal)
                    compare(page.game.claims[a.goal.y * w.cols + a.goal.x], id, id + " claims the tile it stops at, " + a.goal.x + "," + a.goal.y);
                stood[id] = tiles;
            }
            this.stood = stood;
            this.stoodOn = [w.cols, w.xd];
            for (const m of Object.values(page.crew.members)) {
                if (!m.carrying)
                    continue;
                const r = load(m);
                verify(r[0] >= m.px && r[1] >= m.py - 8 && r[0] + r[2] <= m.px + 16 && r[1] + r[3] <= m.py + 16, m.key + "'s desk is drawn within its figure");
            }
        }

        // Sends a person to stand at a tile, claimed as any place it stops at.
        function send(who, x, y) {
            const goal = {
                x: x,
                y: y,
                face: 0,
                offY: 0,
                pose: "stand",
                kind: "floor"
            };
            page.game.claim(who, goal);
            who.setGoal(goal);
        }

        // Takes a person off wherever it is and stands it at a tile.
        function standAt(who, x, y) {
            who.goal = null;
            who.path = [];
            page.game.release(who);
            who.place(x, y, true);
            send(who, x, y);
        }

        // Where a person is drawn, from the top of its head to its shoes (its
        // shadow below them is see-through), and where a carried desk is.
        function body(a) {
            return [a.px, a.py - 8 + a.offY, 16, 21];
        }

        function load(m) {
            const v = find("officeLoad:" + m.key);
            verify(v, m.key + "'s desk is drawn");
            return [m.px + v.x, m.py - 8 + v.y, v.width, v.height];
        }

        function crosses(r, q) {
            return r[0] < q[0] + q[2] && q[0] < r[0] + r[2] && r[1] < q[1] + q[3] && q[1] < r[1] + r[3];
        }

        // Runs the office n ticks, checking the floor after each.
        function walk(n) {
            for (let i = 0; i < n; i++) {
                page.game.advance(1);
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
            tryVerify(() => made.game.columns > 0);
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
            verify(scroller.width >= made.game.columns * 16 && scroller.height > 0, "the office has room to show");
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

        function test_reviewers_sit_in_the_review_corner_with_their_workers() {
            const people = many(4, "t", "working", "typing").concat([reviewer("r", "Review #12")], [reviewer("rw0", "Check tests", "r"), reviewer("rw1", "Check docs", "r")]);
            plugin.publish(people);
            const review = corner();
            verify(review >= 0, "the office has a review corner");
            for (const id of ["r", "rw0", "rw1"])
                compare(page.world.seatOf[id].pod, review, id + " sits in the review corner");
            for (const id of ["t0", "t1", "t2", "t3"])
                verify(page.world.seatOf[id].pod !== review, id + " sits on the floor");
        }

        // A reviewer who comes in later has its desk carried into the corner.
        function test_movers_bring_a_reviewer_its_desk_in_the_corner() {
            plugin.publish(many(2, "t", "working", "typing"));
            plugin.publish(many(2, "t", "working", "typing").concat([reviewer("r", "Review #12")]));
            const seat = page.world.seatOf["r"];
            compare(seat.pod, corner());
            compare(page.jobs, [seat.index], "a desk comes in for the reviewer");
            runUntil(() => page.moves === 0 && arrived(actor("r")), 3000, "the reviewer sits down");
            compare([actor("r").tx, actor("r").ty], [seat.x, seat.y]);
            checkFloor();
        }

        // Reviewers past the corner's eight desks sit at the nearest desks on
        // the floor, and keep them.
        function test_a_full_review_corner_sends_reviewers_to_the_nearest_desks() {
            const reviewers = [];
            for (let i = 0; i < 10; i++)
                reviewers.push(reviewer("r" + i, "Review #" + i));
            plugin.publish(many(2, "t", "working", "typing").concat(reviewers));
            const review = corner();
            const pods = reviewers.map(r => page.world.seatOf[r.id].pod);
            compare(pods.filter(pod => pod === review).length, 8, "the corner is full of reviewers");
            const spilt = reviewers.filter(r => page.world.seatOf[r.id].pod !== review);
            compare(spilt.length, 2);
            const at = pod => page.world.pods[pod];
            const away = pod => Math.abs(at(pod).x - at(review).x) + Math.abs(at(pod).y - at(review).y);
            const nearest = Math.min(...page.world.pods.map((pod, i) => i).filter(i => i !== review).map(away));
            for (const r of spilt)
                compare(away(page.world.seatOf[r.id].pod), nearest, r.id + " sits next to the corner");
            const seats = {};
            for (const r of reviewers)
                seats[r.id] = page.world.seatOf[r.id];
            plugin.publish(many(2, "t", "working", "typing").concat(reviewers.slice(1)));
            for (const r of reviewers.slice(1))
                verify(page.world.seatOf[r.id] === seats[r.id], r.id + " keeps its seat when a corner desk frees up");
        }

        // A reviewer team that did not fit in the full corner seats its
        // newcomers next to its own desks on the floor, not at whichever pod
        // is nearest the corner.
        function test_a_reviewer_team_out_of_the_corner_seats_newcomers_by_its_desks() {
            const team = (id, n) => [person(id, id, "working", "typing")].concat(many(n - 1, id + "w", "working", "typing", id));
            const reviewers = [];
            for (let i = 0; i < 8; i++)
                reviewers.push(reviewer("r" + i, "Review #" + i));
            const s = n => [reviewer("s", "Review #20")].concat([0, 1, 2].slice(0, n - 1).map(i => reviewer("sw" + i, "Check " + i, "s")));
            // Teams x and y fill pods 0 and 1, the reviewers the corner (pod
            // 2), so s sits at pod 5, the one under the corner.
            plugin.publish([].concat(team("x", 8), team("y", 8), reviewers, s(2)));
            const review = corner();
            compare(review, 2);
            for (const r of reviewers)
                compare(page.world.seatOf[r.id].pod, review, r.id + " sits in the corner");
            const pod = page.world.seatOf["s"].pod;
            compare(pod, 5, "s sits at the pod under the corner");
            compare(page.world.seatOf["sw0"].pod, pod, "s's worker sits with it");
            const seats = {};
            for (const p of reviewers.concat(s(2)))
                seats[p.id] = page.world.seatOf[p.id];
            // Pod 1 empties; it is as near the corner as pod 5, and first.
            plugin.publish([].concat(team("x", 8), reviewers, s(3)));
            for (const id of Object.keys(seats))
                verify(page.world.seatOf[id] === seats[id], id + " keeps its seat");
            compare(page.world.seatOf["sw1"].pod, pod, "the newcomer sits by its team's desks");
            // Past its pod's desks too, its newcomers sit at the pod nearest
            // its own, not the one nearest the corner.
            const big = [reviewer("s", "Review #20")].concat([0, 1, 2, 3, 4, 5, 6, 7, 8].map(i => reviewer("sw" + i, "Check " + i, "s")));
            plugin.publish([].concat(team("x", 8), reviewers, big));
            for (const id of ["s", "sw0", "sw1"])
                compare(page.world.seatOf[id].pod, pod, id + " keeps its pod");
            for (const id of ["sw2", "sw3", "sw4", "sw5", "sw6"])
                compare(page.world.seatOf[id].pod, pod, id + " fills its team's pod");
            for (const id of ["sw7", "sw8"])
                compare(page.world.seatOf[id].pod, 4, id + " sits at the pod beside its team's");
        }

        // A team's kind can change once it is seated: a worker in the office
        // before its reviewer lead is no reviewer until the lead's row comes.
        // Seated members keep their seats, so nobody moves while they stay,
        // and the team sits split: the worker on the floor, the lead and
        // whoever joins it later in the corner.
        function test_a_team_that_becomes_reviewers_keeps_its_seats() {
            const worker = person("w", "Check tests", "working", "typing", "r");
            plugin.publish(many(2, "t", "working", "typing").concat([worker]));
            const review = corner();
            const seat = page.world.seatOf["w"];
            verify(seat.pod !== review, "the worker sits on the floor");
            plugin.publish(many(2, "t", "working", "typing").concat([reviewer("r", "Review #12"), reviewer("w", "Check tests", "r")]));
            verify(page.world.seatOf["w"] === seat, "the worker keeps its seat");
            compare(page.world.seatOf["r"].pod, review, "the lead sits in the review corner");
            runUntil(() => page.moves === 0, 3000, "the lead's desk is carried in");
            plugin.publish(many(2, "t", "working", "typing").concat([reviewer("r", "Review #12"), reviewer("w", "Check tests", "r"), reviewer("w2", "Check docs", "r")]));
            verify(page.world.seatOf["w"] === seat, "the worker still keeps its seat");
            compare(page.world.seatOf["w2"].pod, review, "a newcomer sits with the lead");
            compare(actor("w").goal?.kind, "desk", "the worker stays at its desk");
        }

        // A reviewer whose own parent is no reviewer still sits in the corner,
        // and the parent and its other workers on the floor.
        function test_a_reviewer_under_an_ordinary_thread_sits_in_the_corner() {
            plugin.publish([person("lead", "Lead", "working", "typing"), person("lw", "Write tests", "working", "typing", "lead"), reviewer("r", "Review #12", "lead")]);
            const review = corner();
            compare(page.world.seatOf["r"].pod, review, "the reviewer sits in the review corner");
            for (const id of ["lead", "lw"])
                verify(page.world.seatOf[id].pod !== review, id + " sits on the floor");
            compare(page.world.seatOf["lw"].pod, page.world.seatOf["lead"].pod, "the other worker sits with its lead");
        }

        // With the corner full, a reviewer under an ordinary lead sits at the
        // desks nearest the corner, not by its lead.
        function test_a_reviewer_under_an_ordinary_lead_spills_next_to_the_corner() {
            const reviewers = [];
            for (let i = 0; i < 8; i++)
                reviewers.push(reviewer("r" + i, "Review #" + i));
            const team = [person("lead", "Lead", "working", "typing"), person("lw", "Write tests", "working", "typing", "lead")];
            plugin.publish(team.concat(reviewers));
            const review = corner();
            const pod = page.world.seatOf["lead"].pod;
            compare(pod, 0, "the lead sits at the pod across from the corner");
            for (const r of reviewers)
                compare(page.world.seatOf[r.id].pod, review, r.id + " sits in the corner");
            plugin.publish(team.concat([reviewer("lr", "Review the tests", "lead")], reviewers));
            const at = i => page.world.pods[i];
            const away = i => Math.abs(at(i).x - at(review).x) + Math.abs(at(i).y - at(review).y);
            const nearest = Math.min(...page.world.pods.map((_, i) => i).filter(i => i !== review).map(away));
            const seat = page.world.seatOf["lr"];
            verify(seat.pod !== pod, "the reviewer does not sit by its lead");
            compare(away(seat.pod), nearest, "the reviewer sits next to the corner");
        }

        // A defensive test of an inconsistent snapshot, not ledger behaviour:
        // the MC makes every worker under a reviewer one too, so it never
        // sends this. Should one come, ordinary workers under a reviewer lead
        // who do not fit their pod sit at the pod nearest the one their
        // ordinary teammates hold, not the one nearest their lead's corner.
        function test_an_inconsistent_snapshot_spills_ordinary_workers_from_their_own_pod() {
            const x = [person("x", "X", "working", "typing")].concat(many(7, "xw", "working", "typing", "x"));
            const team = n => [reviewer("r", "Review #12")].concat(many(n, "o", "working", "typing", "r"));
            plugin.publish(x.concat(team(8)));
            compare(page.world.seatOf["x"].pod, 0, "team x fills pod 0");
            compare(page.world.seatOf["r"].pod, corner(), "the lead sits in the corner");
            for (let i = 0; i < 8; i++)
                compare(page.world.seatOf["o" + i].pod, 1, "o" + i + " sits at pod 1");
            plugin.publish(x.concat(team(10)));
            for (const id of ["o8", "o9"])
                compare(page.world.seatOf[id].pod, 4, id + " sits at the pod under its teammates'");
        }

        // A planner that turns out to be a reviewer goes to the review
        // whiteboard, and keeps its desk.
        function test_a_planner_that_becomes_a_reviewer_goes_to_the_review_whiteboard() {
            const board = key => page.world.boards.find(b => b.key === key);
            plugin.publish([person("w", "Check tests", "working", "planning", "r")]);
            verify(!board(actor("w").goal.board).review, "the worker plans at another whiteboard");
            const seat = page.world.seatOf["w"];
            plugin.publish([reviewer("r", "Review #12"), Object.assign(reviewer("w", "Check tests", "r"), {
                    activity: "planning"
                })]);
            verify(board(actor("w").goal.board).review, "the reviewer goes to the review whiteboard");
            verify(page.world.seatOf["w"] === seat, "it keeps its desk");
        }

        // A reviewer plans at the review corner's whiteboard, anyone else at
        // the others.
        function test_reviewers_plan_at_the_review_whiteboard() {
            plugin.publish([Object.assign(reviewer("r", "Review #12"), {
                    activity: "planning"
                }), person("t", "T", "working", "planning")]);
            const board = key => page.world.boards.find(b => b.key === key);
            verify(board(actor("r").goal.board).review, "the reviewer goes to the review whiteboard");
            verify(!board(actor("t").goal.board).review, "the other goes to another whiteboard");
        }

        // The corner's desks are for reviewers only: past the floor's desks,
        // the office grows instead.
        function test_others_never_sit_in_the_review_corner() {
            plugin.publish(many(40, "t", "working", "typing"));
            const review = corner();
            const pods = page.world.pods.length;
            for (let i = 0; i < 40; i++)
                verify(page.world.seatOf["t" + i].pod !== review, "t" + i + " sits on the floor");
            plugin.publish(many(42, "t", "working", "typing").concat([reviewer("r", "Review #12")]));
            verify(page.world.pods.length > pods, "the office grows");
            for (let i = 0; i < 42; i++)
                verify(page.world.seatOf["t" + i].pod !== review, "t" + i + " sits on the floor");
            compare(page.world.seatOf["r"].pod, review, "the reviewer has a corner desk");
        }

        // Someone in the corner who is no reviewer leaves it at the next
        // seating, for a desk on the floor, which the office grows for when
        // the floor is full.
        function test_someone_in_the_corner_who_is_no_reviewer_leaves_it() {
            const review = corner();
            plugin.publish([reviewer("a", "Review #12"), reviewer("b", "Review #13")]);
            compare(page.world.seatOf["a"].pod, review);
            compare(page.world.seatOf["b"].pod, review);
            plugin.publish([person("a", "Review #12", "working", "typing"), reviewer("b", "Review #13")]);
            verify(page.world.seatOf["a"].pod !== review, "a sits on the floor");
            compare(page.world.seatOf["b"].pod, review, "b keeps its corner desk");
            open();
            plugin.publish(many(40, "t", "working", "typing").concat([reviewer("a", "Review #12")]));
            compare(page.world.seatOf["a"].pod, review);
            plugin.publish(many(40, "t", "working", "typing").concat([person("a", "Review #12", "working", "typing")]));
            verify(page.world.seatOf["a"] && page.world.seatOf["a"].pod !== review, "with the floor full, the office grows and a sits on the floor");
            compare(page.world.pods[review].members, [], "the corner is empty");
        }

        // Reviewers past the corner's desks take floor desks, and every other
        // thread still has one, wherever they come in the list.
        function test_reviewers_past_the_corner_sit_on_the_floor() {
            const reviewers = [];
            for (let i = 0; i < 10; i++)
                reviewers.push(reviewer("r" + i, "Review #" + i));
            // Eight teams of 5: five fill pods 0, 1, 3, 4 and 5 to 5 of 8,
            // and the last three, which fit no pod whole, take the rest.
            const teams = [];
            for (let t = 0; t < 8; t++)
                teams.push(...[person("l" + t, "Lead " + t, "working", "typing")].concat(many(4, "w" + t + "_", "working", "typing", "l" + t)));
            plugin.publish(reviewers.concat(teams));
            const review = corner();
            for (const p of teams)
                verify(page.world.seatOf[p.id] && page.world.seatOf[p.id].pod !== review, p.id + " has a floor desk");
            compare(reviewers.filter(r => page.world.seatOf[r.id]?.pod === review).length, 8, "the corner is full of reviewers");
            compare(reviewers.filter(r => page.world.seatOf[r.id] && page.world.seatOf[r.id].pod !== review).length, 2, "the other 2 reviewers sit on the floor");
        }

        // A reviewer on a floor desk counts as one more desk the office needs,
        // so when threads fill the floor the office grows instead of taking
        // the desk from it: the reviewers keep their desks, and every thread
        // has one on the floor.
        function test_reviewers_on_the_floor_keep_their_desks_as_the_office_grows() {
            const reviewers = [];
            for (let i = 0; i < 10; i++)
                reviewers.push(reviewer("r" + i, "Review #" + i));
            plugin.publish(reviewers);
            const review = corner();
            const seats = {};
            for (const r of reviewers)
                seats[r.id] = page.world.seatOf[r.id].index;
            verify(page.world.seatOf["r8"].pod !== review && page.world.seatOf["r9"].pod !== review, "r8 and r9 sit on the floor");
            // r0 leaves the corner, and 40 threads need every floor desk.
            plugin.publish(reviewers.slice(1).concat(many(40, "t", "working", "typing")));
            verify(page.world.pods.length > 6, "the office grows");
            for (let i = 0; i < 40; i++)
                verify(page.world.seatOf["t" + i] && page.world.seatOf["t" + i].pod !== corner(), "t" + i + " has a floor desk");
            for (let i = 1; i < 10; i++)
                compare(page.world.seatOf["r" + i]?.index, seats["r" + i], "r" + i + " keeps its desk");
        }

        // Someone reading at a shelf who loses its corner desk on a full floor
        // gets a desk on the floor, the office growing for it, and reads on.
        function test_a_reader_who_leaves_the_corner_on_a_full_floor_gets_a_floor_desk() {
            const reading = p => Object.assign(p, {
                    activity: "reading"
                });
            plugin.publish(many(40, "t", "working", "typing").concat([reading(reviewer("a", "Review #12"))]));
            compare(actor("a").goal.kind, "shelf", "a reads at a shelf");
            const pods = page.world.pods.length;
            plugin.publish(many(40, "t", "working", "typing").concat([reading(person("a", "Review #12", "working"))]));
            verify(page.world.pods.length > pods, "the office grows");
            verify(page.world.seatOf["a"] && page.world.seatOf["a"].pod !== corner(), "a sits on the floor");
            compare(actor("a").goal.kind, "shelf", "a reads on");
        }

        // An office that grows so everyone has a desk keeps the review corner
        // for reviewers on every tick: no other thread sits or steps on its
        // seats, every one has a floor desk, the reviewers past the corner
        // hot-desk on the floor, and one in the corner that is a reviewer no
        // more leaves it at once for the floor.
        function test_an_office_growing_for_everyone_keeps_the_corner_for_reviewers() {
            icons({
                "local:p-api": {
                    kind: "monogram",
                    text: "AP",
                    tint: "#4A90D9"
                }
            });
            const reviewers = [];
            for (let i = 0; i < 12; i++)
                reviewers.push(reviewer("r" + i, "Review #" + i));
            const leaving = {};
            const run = (people, ticks, full) => {
                const ordinary = people.filter(p => p.kind !== "reviewer");
                for (let i = 0; i < ticks; i++) {
                    const w = page.world, review = corner();
                    const tiles = {};
                    for (const seat of w.pods[review].seats)
                        tiles[seat.y * w.cols + seat.x] = true;
                    for (const p of ordinary) {
                        const seat = w.seatOf[p.id], a = actor(p.id);
                        verify(seat && seat.pod !== review, p.id + " has a floor desk");
                        const on = tiles[a.ty * w.cols + a.tx] || a.next >= 0 && tiles[a.next];
                        if (!leaving[p.id])
                            verify(!on, p.id + " never sits in the review corner");
                        else if (!on)
                            delete leaving[p.id];
                    }
                    const inCorner = reviewers.filter(r => people.includes(r) && w.seatOf[r.id]?.pod === review);
                    compare(inCorner.length, full, "the corner holds " + full + " reviewers");
                    for (const r of people.filter(p => p.kind === "reviewer")) {
                        verify(w.seatOf[r.id], r.id + " has a desk");
                        verify(!markOf(r.id).visible, r.id + "'s desk shows no project");
                    }
                    page.game.advance(1);
                }
            };
            const first = many(36, "t", "working", "typing").concat(reviewers);
            plugin.publish(first);
            const pods = page.world.pods.length;
            run(first, 300, 8);
            // Fifty threads and twelve reviewers need more desks than six pods.
            const grown = many(50, "t", "working", "typing").concat(reviewers);
            plugin.publish(grown);
            verify(page.world.pods.length > pods, "the office grows");
            run(grown, 400, 8);
            // A reviewer in the corner that is a reviewer no more.
            const was = reviewers.find(r => page.world.seatOf[r.id].pod === corner());
            const demoted = grown.map(p => p === was ? person(was.id, was.title, "working", "typing") : p);
            reviewers.splice(reviewers.indexOf(was), 1);
            leaving[was.id] = true;
            plugin.publish(demoted);
            // The reviewers on the floor keep their desks there.
            run(demoted, 600, 7);
            verify(!leaving[was.id], was.id + " has left the corner");
        }

        // Reviewers hot-desk: no desk of theirs shows a project, in the corner
        // or on the floor.
        function test_reviewers_desks_show_no_project() {
            icons({
                "local:p-api": {
                    kind: "monogram",
                    text: "AP",
                    tint: "#4A90D9"
                }
            });
            const reviewers = [];
            for (let i = 0; i < 9; i++)
                reviewers.push(reviewer("r" + i, "Review #" + i));
            plugin.publish([person("t", "T", "working", "typing")].concat(reviewers));
            const review = corner();
            verify(markOf("t").visible, "an ordinary desk shows its project");
            const spilt = reviewers.filter(r => page.world.seatOf[r.id].pod !== review);
            compare(spilt.length, 1, "one reviewer sits on the floor");
            for (const r of reviewers)
                verify(!markOf(r.id).visible, r.id + "'s desk shows no project");
            // Nor once the project's look changes.
            icons({
                "local:p-api": {
                    kind: "emoji",
                    emoji: "🎉"
                }
            });
            for (const r of reviewers)
                verify(!markOf(r.id).visible, r.id + "'s desk still shows no project");
            verify(markOf("t").visible);
        }

        function test_a_desk_shows_its_project_as_the_sidebar_does() {
            icons({
                "local:p-api": {
                    kind: "monogram",
                    text: "AP",
                    color: "blue",
                    tint: "#4A90D9",
                    automatic: false
                },
                "local:p-fun": {
                    kind: "emoji",
                    emoji: "🎉",
                    automatic: false
                },
                "local:p-logo": {
                    kind: "image",
                    url: "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='4' height='4'/>",
                    text: "LO",
                    tint: "#e05d5d",
                    automatic: true
                }
            });
            const at = (id, projectId, project) => Object.assign(person(id, id, "working", "typing"), {
                projectId: projectId,
                project: project
            });
            plugin.publish([at("a", "p-api", "api"), at("b", "p-fun", "fun"), at("c", "p-logo", "logo"), at("d", "p-web", "web")]);
            const a = markOf("a");
            verify(a.visible, "a's desk shows its project");
            compare([a.kind, a.label, a.tint], ["tile", "AP", "#4a90d9"]);
            compare([markOf("b").kind, markOf("b").emoji], ["emoji", "🎉"]);
            compare([markOf("c").kind, markOf("c").label, markOf("c").tint], ["image", "LO", "#e05d5d"]);
            verify(markOf("c").url.indexOf("data:image/svg") === 0);
            // A project the sidebar has no icon for shows its first letter, uncoloured.
            compare([markOf("d").kind, markOf("d").label, markOf("d").tint], ["tile", "W", "#8b919e"]);
            // A project's new look reaches its desks.
            icons({
                "local:p-api": {
                    kind: "monogram",
                    text: "AX",
                    tint: "#5fbf7a"
                }
            });
            compare([a.label, a.tint], ["AX", "#5fbf7a"]);
            compare([markOf("b").kind, markOf("b").label], ["tile", "F"]);
        }

        // A desk with nobody at it, or out of the office, shows no project.
        function test_a_desk_nobody_has_shows_no_project() {
            plugin.publish([person("a", "A", "working", "typing"), person("b", "B", "working", "typing")]);
            const mark = markOf("a");
            verify(mark.visible);
            plugin.publish([person("b", "B", "working", "typing")]);
            verify(!mark.visible, "the desk being carried out shows no project");
            runUntil(() => page.moves === 0, 3000, "the desk is carried out");
            verify(!mark.visible);
            verify(markOf("b").visible);
        }

        // The marks are painted once, and again only when a project's look changes.
        function test_desk_marks_are_painted_only_when_a_project_changes() {
            const web = Object.assign(person("w", "W", "working", "typing"), {
                projectId: "p-web",
                project: "web"
            });
            plugin.publish(many(6, "t", "working", "typing").concat([web]));
            tryVerify(() => page.markPaints >= 7);
            wait(50);
            const paints = page.markPaints;
            page.game.advance(200);
            plugin.publish(many(6, "t", "working", "typing").concat([web]));
            page.game.advance(200);
            wait(50);
            compare(page.markPaints, paints, "nothing repaints while nothing changes");
            icons({
                "local:p-web": {
                    kind: "monogram",
                    text: "WB",
                    tint: "#e8894a"
                }
            });
            tryVerify(() => page.markPaints > paints);
            wait(50);
            compare(page.markPaints, paints + 1, "only the web desk repaints");
        }

        function test_people_walk_around_furniture_and_never_stop_on_one_tile() {
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

        // Someone leaving leaves its desk to whoever comes next; everyone
        // else stays where they are.
        function test_a_desk_left_behind_is_taken_by_whoever_comes_next() {
            plugin.publish([person("a", "A", "working", "typing"), person("b", "B", "working", "typing")]);
            const world = page.world;
            const a = page.world.seatOf["a"], b = page.world.seatOf["b"];
            plugin.publish([person("b", "B", "working", "typing"), person("c", "C", "working", "typing")]);
            verify(page.world === world, "the same office");
            verify(page.world.seatOf["b"] === b, "B keeps its desk");
            verify(page.world.seatOf["c"] === a, "C takes A's desk");
            compare(page.moves, 0, "nobody carries a desk");
            runUntil(() => arrived(actor("c")), 1500, "C reaches its desk");
            compare([actor("c").tx, actor("c").ty], [a.x, a.y]);
            compare([actor("b").tx, actor("b").ty], [b.x, b.y], "B never got up");
        }

        // People sharing a pod keep their seats when a teammate joins a team
        // seated before theirs, or someone between them leaves.
        function test_people_keep_their_seats_as_others_come_and_go() {
            const a = [person("a", "A", "working", "typing"), person("aw0", "AW 0", "working", "typing", "a")];
            const b = [person("b", "B", "working", "typing")].concat(many(2, "bw", "working", "typing", "b"));
            plugin.publish(a.concat(b));
            const pod = page.world.seatOf["a"].pod;
            compare(page.world.seatOf["b"].pod, pod, "the teams share a pod");
            const seats = {};
            for (const p of a.concat(b))
                seats[p.id] = page.world.seatOf[p.id];
            plugin.publish(a.concat([person("aw1", "AW 1", "working", "typing", "a")], b));
            compare(page.world.seatOf["aw1"].pod, pod, "the new worker sits with its lead");
            for (const id of Object.keys(seats))
                verify(page.world.seatOf[id] === seats[id], id + " keeps its seat");
            runUntil(() => page.moves === 0, 1500, "aw1's desk is carried in");
            plugin.publish([a[0]].concat([person("aw1", "AW 1", "working", "typing", "a")], b));
            for (const id of ["a", "b", "bw0", "bw1"])
                verify(page.world.seatOf[id] === seats[id], id + " keeps its seat after aw0 leaves");
            compare(page.jobs.length, 1, "only aw0's desk goes");
            for (const id of ["a", "b", "bw0", "bw1"])
                compare(actor(id).goal?.kind, "desk", id + " stays at its desk");
        }

        // A team that outgrows its pod keeps it, and only the newcomers who do
        // not fit sit at the nearest pod with room.
        function test_a_team_that_outgrows_its_pod_stays_put() {
            const lead = person("a", "A", "working", "typing");
            const team = n => [lead].concat(many(n, "aw", "working", "typing", "a"));
            plugin.publish([person("x", "X", "working", "typing")].concat(team(6)));
            const seats = {};
            for (const p of team(6))
                seats[p.id] = page.world.seatOf[p.id];
            const pod = seats["a"].pod;
            plugin.publish([person("x", "X", "working", "typing")].concat(team(7)));
            for (const id of Object.keys(seats))
                verify(page.world.seatOf[id] === seats[id], id + " keeps its seat");
            verify(page.world.seatOf["aw6"].pod !== pod, "the newcomer sits at another pod");
            compare(page.jobs.length, 1, "one desk comes in");
            // Someone who sat down at another pod keeps that seat, even when
            // newcomers fill every other pod near it.
            const aside = page.world.seatOf["aw6"].index;
            const z = [person("z", "Z", "working", "typing")].concat(many(31, "zw", "working", "typing", "z"));
            plugin.publish([person("x", "X", "working", "typing")].concat(team(7), z));
            compare(page.world.seatOf["aw6"].index, aside, "aw6 keeps its seat");
            compare(Object.keys(page.world.seatOf).filter(id => page.world.seatOf[id].index === aside), ["aw6"]);
        }

        // A team that outgrows its pod with nobody of the new lot seated yet
        // sits at the free pod nearest its own, not the first free one.
        function test_a_team_that_outgrows_its_pod_goes_to_the_nearest_free_pod() {
            const team = (id, n) => [person(id, id, "working", "typing")].concat(many(n - 1, id + "w", "working", "typing", id));
            // Five teams fill the floor's pods 0, 1, 3, 4 and 5; pod 2 is the
            // review corner.
            const all = ["x", "y", "z", "u", "a"].map(id => team(id, 8));
            plugin.publish([].concat(...all));
            compare(page.world.seatOf["a"].pod, 5, "team a fills the last pod");
            const seats = {};
            for (const p of all[4])
                seats[p.id] = page.world.seatOf[p.id];
            // Pods 0 and 4 empty out; pod 4 is next to pod 5, pod 0 is across
            // the office, and the corner next to it is not for them.
            plugin.publish([].concat(all[1], all[2], all[4], [person("aw7", "aw 7", "working", "typing", "a")]));
            for (const id of Object.keys(seats))
                verify(page.world.seatOf[id] === seats[id], id + " keeps its seat");
            compare(page.world.seatOf["aw7"].pod, 4, "the newcomer sits at the free pod nearest its team");
        }

        // Everyone has a desk: the office is six pods in two rows, 48 desks,
        // and grows when people outnumber its desks, to the grid of pods that
        // shows biggest in the view: in this wide one, a pod to each row
        // first. It shrinks only once a pod's worth of desks would still be
        // free in a smaller grid, after the desks in the pods it loses are
        // carried out, and is painted again only when it changes size.
        function test_the_office_grows_by_pods_and_shrinks_back() {
            const seated = n => {
                for (let i = 0; i < n; i++)
                    verify(page.world.seatOf["t" + i] !== undefined, "t" + i + " has a desk");
            };
            const grid = () => [page.world.across, page.world.pods.length];
            // Six pods hold 40 people; the review corner's 8 desks are for
            // reviewers only.
            plugin.publish(many(40, "t", "working", "typing"));
            const cols = page.game.columns, rows = page.game.rows;
            compare(grid(), [3, 6]);
            compare(page.world.seats.length, 48);
            seated(40);
            const seats = {};
            for (let i = 0; i < 40; i++)
                seats["t" + i] = page.world.seatOf["t" + i].index;
            walk(50);
            wait(50);
            const paints = page.floorPaints;

            plugin.publish(many(41, "t", "working", "typing"));
            compare(grid(), [4, 8], "a pod more to each row");
            compare(page.game.rows, rows, "as deep as before");
            compare(page.world.seats.length, 64);
            seated(41);
            for (const id of Object.keys(seats))
                compare(page.world.seatOf[id].index, seats[id], id + " keeps its seat");
            compare(page.world.seatOf["t40"].pod >= 6, true, "the newcomer sits in a new pod");
            wait(50);
            compare(page.floorPaints, paints + 1, "the floor is painted once for the new size");
            walk(300);
            plugin.publish(many(56, "t", "working", "typing"));
            compare(grid(), [4, 8], "56 people fit");
            plugin.publish(many(70, "t", "working", "typing"));
            compare(grid(), [4, 12], "a row of pods more");
            compare(page.game.rows, rows + 6);
            compare(page.world.entrance, [2, rows + 4], "the entrance moves down with the wall");
            seated(70);
            walk(300);
            wait(50);
            compare(page.floorPaints, paints + 2, "painted only when the size changed");
            runUntil(() => page.moves === 0, 6000, "every desk is in");

            // 57 people would leave less than a pod free in a smaller grid,
            // 56 a pod: the desks in the pods it loses are carried out, then
            // it shrinks.
            plugin.publish(many(57, "t", "working", "typing"));
            compare(page.closeTo, 0, "57 people keep twelve pods");
            plugin.publish(many(56, "t", "working", "typing"));
            compare(grid(), [4, 12], "the office waits for the desks to go");
            compare(page.closeTo, 9);
            for (const id of Object.keys(page.world.seatOf))
                verify(page.world.seatOf[id].pod < 9, id + " moves out of the closing pods");
            runUntil(() => page.world.pods.length === 9, 6000, "the office shrinks");
            compare(grid(), [3, 9]);
            seated(56);
            walk(600);
            plugin.publish(many(49, "t", "working", "typing"));
            compare(page.closeTo, 0, "49 people keep nine pods");
            plugin.publish(many(32, "t", "working", "typing"));
            compare(page.closeTo, 6, "32 people leave a pod free in six");
            runUntil(() => page.world.pods.length === 6, 6000, "the office shrinks back to its first size");
            compare([page.game.columns, page.game.rows], [cols, rows]);
            seated(32);
            walk(400);
            // Past 40 people again, it grows at once.
            plugin.publish(many(41, "t", "working", "typing"));
            compare(grid(), [4, 8]);
            walk(200);
        }

        // Gives the page a view of `w` by `h` and waits for its layout.
        function resize(w, h) {
            const scroller = find("officeScroller");
            loader.width = w;
            loader.height = h;
            tryVerify(() => scroller.width > w - 100 && scroller.width <= w && scroller.height > h - 200 && scroller.height <= h, 1000, "the view is " + w + " by " + h);
            // The office fits itself to the view once the resize is done.
            wait(0);
        }

        // How big an office of `cols` by `rows` tiles shows, fitted to the view.
        function fitOf(cols, rows) {
            const scroller = find("officeScroller");
            return Math.min((scroller.width - 8) / (cols * 16), (scroller.height - 8) / (rows * 16));
        }

        // A big office takes the grid of pods that shows it biggest: wider in
        // a wide view than in a tall one, and in a wide one bigger than rows
        // of three pods would. In a view that wants another grid everyone
        // keeps its desk and walks there from where it was.
        function test_a_big_office_is_wider_in_a_wide_view_than_a_tall_one() {
            resize(1600, 900);
            plugin.publish(many(70, "t", "working", "typing"));
            const wide = page.world.across;
            // Rows of three pods: four rows for 70 people.
            verify(page.game.fitScale > fitOf(33, 31), "it shows bigger than in rows of three: " + page.game.fitScale + " against " + fitOf(33, 31));
            const seats = {}, at = {};
            for (const id of Object.keys(page.game.actors)) {
                seats[id] = page.world.seatOf[id].index;
                at[id] = [actor(id).tx, actor(id).ty];
            }
            resize(700, 1300);
            const tall = page.world.across;
            verify(wide > tall, "more pods to a row in a wide view: " + wide + " against " + tall);
            for (const id of Object.keys(seats)) {
                const a = actor(id);
                compare(page.world.seatOf[id].index, seats[id], id + " keeps its desk");
                // Those where the break room now is step to the office's
                // floor by its wall.
                if (at[id][0] < page.world.xd && at[id][1] < page.world.rows)
                    verify(Math.abs(a.tx - at[id][0]) + Math.abs(a.ty - at[id][1]) <= 2, id + " is still near where it was");
                else
                    verify(a.tx < page.world.xd, id + " stays out of the break room");
            }
            for (const id of Object.keys(seats)) {
                const seat = page.world.seatOf[id];
                runUntil(() => arrived(actor(id)) && actor(id).tx === seat.x && actor(id).ty === seat.y, 1500, id + " walks to its desk");
            }
            checkFloor();
        }

        // The six pods an office starts with stay two rows of three in an
        // ordinary window.
        function test_the_first_six_pods_stay_two_rows_of_three() {
            for (const size of [[1200, 760], [1024, 700], [1920, 1080]]) {
                resize(size[0], size[1]);
                open();
                plugin.publish(many(12, "t", "working", "typing"));
                compare([page.world.across, page.world.pods.length, page.game.columns, page.game.rows], [3, 6, 33, 19], size.join("×"));
            }
        }

        // In a tall, narrow view the pods stack in a single column, the
        // review corner on top by the break room.
        function test_a_narrow_view_stacks_the_pods_in_one_column() {
            resize(300, 1000);
            plugin.publish(many(12, "t", "working", "typing").concat([reviewer("r0", "Review 0")]));
            compare([page.world.across, page.world.pods.length], [1, 6]);
            verify(page.game.fitScale > fitOf(27, 25), "it shows bigger than two across: " + page.game.fitScale + " against " + fitOf(27, 25));
            const corner = page.world.pods.find(pod => pod.review);
            compare(corner.y, Math.min(...page.world.pods.map(pod => pod.y)), "the review corner is the top pod");
            compare(page.world.seatOf["r0"].pod, page.world.pods.indexOf(corner), "the reviewer sits there");
            verify(page.boards.some(board => board.review), "under its whiteboard");
            for (const id of Object.keys(page.game.actors)) {
                const seat = page.world.seatOf[id];
                runUntil(() => arrived(actor(id)) && actor(id).tx === seat.x && actor(id).ty === seat.y, 3000, id + " gets to its desk");
            }
            checkFloor();
        }

        // Two talking when the office takes another grid talk on from the
        // same tiles, and keep them for the rest of the talk.
        function test_a_talk_keeps_its_tiles_through_a_resize() {
            const people = [person("lead", "Lead", "working", "typing"), person("c", "C", "waiting")];
            plugin.publish(people);
            const a = actor("lead"), c = actor("c");
            page.takeBreak(c);
            runUntil(() => arrived(c) && c.tx > page.world.xd, 3000, "C gets to the break room");
            plugin.publish(people, [
                {
                    id: "talk-1",
                    from: "lead",
                    to: "c",
                    kind: "message",
                    text: "Got a minute?",
                    at: new Date().toISOString()
                }
            ]);
            runUntil(() => a.talk?.phase === "say", 3000, "the talk starts");
            const across = page.world.across;
            resize(300, 1000);
            verify(page.world.across !== across, "the office takes another grid");
            compare(Math.abs(a.tx - c.tx) + Math.abs(a.ty - c.ty), 1, "the two are still side by side");
            const W = page.world.cols, side = a.ty * W + a.tx, here = c.ty * W + c.tx;
            checkFloor();
            runUntil(() => {
                if (!a.talk)
                    return true;
                compare(page.game.claims[side], "lead", "the lead keeps the side it talks from");
                compare(page.game.claims[here], "c", "C keeps the tile it listens on");
                checkFloor();
                return false;
            }, 400, "the talk ends");
        }

        // Whatever clears the claims mid-talk, the next step of the talk
        // claims the speaker's side and the listener's tile again.
        function test_a_talk_claims_its_tiles_again_when_they_go_missing() {
            const people = [person("lead", "Lead", "working", "typing"), person("c", "C", "waiting")];
            plugin.publish(people);
            const a = actor("lead"), c = actor("c");
            plugin.publish(people, [
                {
                    id: "talk-1",
                    from: "lead",
                    to: "c",
                    kind: "message",
                    text: "Got a minute?",
                    at: new Date().toISOString()
                }
            ]);
            runUntil(() => a.talk?.phase === "say", 3000, "the talk starts");
            const W = page.world.cols, side = a.ty * W + a.tx, here = c.ty * W + c.tx;
            delete page.game.claims[side];
            delete page.game.claims[here];
            a.claim = -1;
            c.hold = -1;
            page.game.advance(1);
            compare([page.game.claims[side], page.game.claims[here]], ["lead", "c"], "both are claimed again");
            compare([a.claim, c.hold], [side, here]);
        }

        // A speaker walking up to a listener talks from beside it, even from
        // straight below, where the side below would be nearer, so neither's
        // speech bubble covers the other.
        function test_a_speaker_walks_up_beside_the_listener() {
            const people = [person("lead", "Lead", "working", "typing"), person("c", "C", "working", "planning")];
            plugin.publish(people);
            const a = actor("lead"), c = actor("c");
            runUntil(() => arrived(c), 3000, "C stands at the whiteboard");
            const W = page.world.cols;
            const beside = [[c.tx - 1, c.ty], [c.tx + 1, c.ty]].filter(([x, y]) => page.game.walkable(x, y) && page.game.claims[y * W + x] === undefined);
            verify(beside.length > 0, "a side beside C is free");
            let below = 0;
            while (below < 3 && page.game.walkable(c.tx, c.ty + below + 1))
                below++;
            verify(below >= 2, "the floor below C is open");
            standAt(a, c.tx, c.ty + below);
            plugin.publish(people, [
                {
                    id: "talk-1",
                    from: "lead",
                    to: "c",
                    kind: "message",
                    text: "Got a minute?",
                    at: new Date().toISOString()
                }
            ]);
            runUntil(() => a.talk?.phase === "go" && a.goal?.kind === "talk", 400, "Lead sets out for C");
            compare(a.goal.y, c.ty, "Lead heads for a side beside C, not the one below");
            runUntil(() => {
                checkFloor();
                return a.talk?.phase === "say";
            }, 3000, "the talk starts");
            compare(a.ty, c.ty, "Lead talks from beside C");
        }

        // A speaker whose side someone else took while the claims were gone
        // walks to the nearest other free side of the listener and talks from
        // there, and nobody stops on one tile with someone else.
        function test_a_speaker_whose_side_was_taken_moves_to_another() {
            // C plans at a whiteboard, out in the open, so the talk can move
            // to either side of it.
            const people = [person("lead", "Lead", "working", "typing"), person("c", "C", "working", "planning"), person("x", "X", "waiting")];
            plugin.publish(people);
            const a = actor("lead"), c = actor("c"), x = actor("x");
            runUntil(() => arrived(c), 3000, "C stands at the whiteboard");
            plugin.publish(people, [
                {
                    id: "talk-1",
                    from: "lead",
                    to: "c",
                    kind: "message",
                    text: "Got a minute?",
                    at: new Date().toISOString()
                }
            ]);
            runUntil(() => a.talk?.phase === "say", 3000, "the talk starts");
            checkFloor();
            const W = page.world.cols, side = a.ty * W + a.tx;
            delete page.game.claims[side];
            a.claim = -1;
            x.goal = {
                x: a.tx,
                y: a.ty,
                face: 0,
                offY: 0,
                pose: "stand",
                kind: "stand"
            };
            page.game.claim(x, x.goal);
            const [ox, oy] = [a.tx, a.ty];
            page.game.advance(1);
            verify(a.claim !== side, "the speaker gives the taken side up");
            compare(Math.abs(a.goal.x - c.tx) + Math.abs(a.goal.y - c.ty), 1, "it heads for another side of the listener");
            // The nearest free side is one of the two beside its old one, two
            // steps away; the one across the listener is a walk of four
            // around it.
            const free = [[-1, 0], [1, 0], [0, -1], [0, 1]].map(([dx, dy]) => [c.tx + dx, c.ty + dy]).filter(([sx, sy]) => page.game.walkable(sx, sy) && [undefined, "lead"].includes(page.game.claims[sy * W + sx]));
            const across = [2 * c.tx - ox, 2 * c.ty - oy];
            verify(free.some(([sx, sy]) => sx === across[0] && sy === across[1]), "the side across the listener is free");
            verify(free.some(([sx, sy]) => sx !== across[0] || sy !== across[1]), "and so is one beside the old one");
            verify(a.goal.x !== across[0] || a.goal.y !== across[1], "it takes a side beside its old one, not the one across the listener");
            compare(Math.abs(a.goal.x - ox) + Math.abs(a.goal.y - oy), 2, "two steps away");
            compare(page.game.claims[a.claim], "lead", "and claims it");
            compare(a.talk.phase, "go");
            runUntil(() => {
                checkFloor();
                return a.talk?.phase === "say";
            }, 3000, "it talks from the other side");
            compare(a.ty * W + a.tx, a.claim, "it stands on the side it claimed");
            runUntil(() => {
                checkFloor();
                return !a.talk;
            }, 12000, "the talk ends");
        }

        // A speaker with no free side left by the listener ends the talk.
        function test_a_speaker_with_no_free_side_ends_the_talk() {
            const people = [person("lead", "Lead", "working", "typing"), person("c", "C", "waiting")];
            plugin.publish(people);
            const a = actor("lead"), c = actor("c");
            plugin.publish(people, [
                {
                    id: "talk-1",
                    from: "lead",
                    to: "c",
                    kind: "message",
                    text: "Got a minute?",
                    at: new Date().toISOString()
                }
            ]);
            runUntil(() => a.talk?.phase === "say", 3000, "the talk starts");
            const W = page.world.cols;
            a.claim = -1;
            for (const [dx, dy] of [[-1, 0], [1, 0], [0, -1], [0, 1]])
                page.game.claims[(c.ty + dy) * W + c.tx + dx] = "someone";
            page.game.advance(1);
            verify(!a.talk, "the talk ends");
            compare(c.heldBy, "", "the listener is let go");
            compare(c.hold, -1, "and holds no tile");
        }

        // Someone stepping through the break room's door when the door moves
        // moves with it and goes on with the step, never back out to the
        // office's floor nor straight through what lies between.
        function test_a_step_through_the_door_goes_on_after_a_resize() {
            plugin.publish([person("c", "C", "working", "typing")]);
            const c = actor("c");
            plugin.publish([person("c", "C", "waiting")]);
            page.takeBreak(c);
            const xd = page.world.xd, W = page.world.cols;
            runUntil(() => c.next >= 0 && c.tx === xd - 1 && c.next % W === xd, 3000, "C steps through the door");
            page.game.advance(2);
            const y = c.ty, offset = c.px - c.tx * 16;
            resize(300, 1000);
            const w = page.world;
            verify(w.xd !== xd, "the door moves");
            compare([c.tx, c.ty, c.next], [w.xd - 1, y, y * w.cols + w.xd], "C goes on stepping through the door where it is now");
            compare(c.px - c.tx * 16, offset, "from as far as it got");
            checkFloor();
            runUntil(() => {
                checkFloor();
                verify(c.tx >= page.world.xd - 1, "C is never put back on the office's floor, at " + c.tx + "," + c.ty);
                return arrived(c) && c.tx > page.world.xd;
            }, 3000, "C goes on to the break room");
        }

        // Someone stepping out of the break room's door when the door moves
        // moves with it too and goes on with the step to the office.
        function test_a_step_out_of_the_door_goes_on_after_a_resize() {
            plugin.publish([person("c", "C", "working", "typing")]);
            const c = actor("c");
            plugin.publish([person("c", "C", "waiting")]);
            page.takeBreak(c);
            runUntil(() => arrived(c) && c.tx > page.world.xd && c.until !== Infinity, 3000, "C gets to the break room");
            c.until = page.game.now;
            const xd = page.world.xd, W = page.world.cols;
            runUntil(() => c.next >= 0 && c.tx === xd && c.next % W === xd - 1, 3000, "C steps out through the door");
            page.game.advance(2);
            const y = c.ty, offset = c.px - c.tx * 16;
            resize(300, 1000);
            const w = page.world;
            verify(w.xd !== xd, "the door moves");
            compare([c.tx, c.ty, c.next], [w.xd, y, y * w.cols + w.xd - 1], "C goes on stepping out of the door where it is now");
            compare(c.px - c.tx * 16, offset, "from as far as it got");
            checkFloor();
            const seat = page.world.seatOf["c"];
            runUntil(() => {
                checkFloor();
                return arrived(c) && c.tx === seat.x && c.ty === seat.y;
            }, 3000, "C gets back to its desk");
        }

        // Someone mid-step when a resize puts the office's south wall on the
        // tile it steps from goes on from the nearest floor, not from inside
        // the wall.
        function test_a_step_from_where_a_wall_comes_goes_on_from_the_floor() {
            resize(300, 1000);
            plugin.publish(many(70, "t", "working", "typing"));
            runUntil(() => page.moves === 0, 6000, "every desk is in");
            compare(page.world.across, 1);
            // The south wall of an office of three rows of pods.
            const y = 6 * 3 + 7 - 1, W = page.world.cols;
            let x = 1;
            while (x < page.world.xd && !(page.game.walkable(x, y) && page.game.walkable(x, y - 1)))
                x++;
            verify(x < page.world.xd, "the floor is open where the wall will be");
            const a = actor("t0");
            standAt(a, x, y);
            send(a, x, y - 1);
            page.game.advance(2);
            compare([a.tx, a.ty, a.next], [x, y, (y - 1) * W + x], "t0 steps north from where the wall will be");
            resize(1200, 760);
            compare([page.world.across, page.world.rows], [4, y + 1], "the south wall is where t0 steps from");
            const w = page.world;
            verify(page.game.plan().grid[a.ty * w.cols + a.tx] !== 1, "t0 is not left in the wall");
            if (a.next >= 0)
                verify(page.game.plan().grid[a.next] !== 1, "nor steps into one");
            else
                compare([a.px, a.py], [a.tx * 16, a.ty * 16], "t0 stands on its tile");
            const seat = w.seatOf["t0"];
            runUntil(() => arrived(a) && a.tx === seat.x && a.ty === seat.y, 3000, "t0 gets to its desk");
        }

        // When a resize moves the break room's wall west, over where people
        // sit and walk, those in the office stay out of the break room: they
        // step to the office's floor by the wall and walk to their desks.
        function test_a_resize_that_moves_the_break_room_keeps_the_office_out_of_it() {
            resize(1200, 760);
            plugin.publish(many(70, "t", "working", "typing"));
            runUntil(() => page.moves === 0, 6000, "every desk is in");
            compare(page.world.across, 4);
            const xd = page.world.xd;
            const office = Object.keys(page.game.actors).filter(id => actor(id).tx < xd);
            compare(office.length, 70, "everyone is in the office");
            // One of them is mid-step where the wall will be.
            const a = actor("t0"), W = page.world.cols, wall = 3 + 4 + 2;
            let y = 3;
            while (y < page.world.rows && !(page.game.walkable(wall, y) && page.game.walkable(wall + 1, y)))
                y++;
            standAt(a, wall + 1, y);
            send(a, wall, y);
            page.game.advance(2);
            compare(a.next, y * W + wall, "t0 steps onto where the wall will be");
            checkFloor();
            resize(300, 1000);
            compare([page.world.across, page.world.xd], [1, wall], "the wall moves west of where people sat");
            const w = page.world;
            for (const id of office) {
                const p = actor(id);
                verify(p.tx < w.xd, id + " stays out of the break room, not at " + p.tx + "," + p.ty);
                if (p.next >= 0)
                    verify(p.next % w.cols < w.xd, id + " steps no further than the office");
            }
            checkFloor();
            walk(100);
        }

        // A resize while the office is closing pods closes it down to what
        // the new view needs, with everyone seated and on the floor.
        function test_a_resize_while_the_office_shrinks() {
            resize(1600, 900);
            plugin.publish(many(70, "t", "working", "typing"));
            walk(200);
            plugin.publish(many(40, "t", "working", "typing"));
            verify(page.closeTo > 0, "40 people leave a pod free");
            resize(700, 1300);
            verify(page.closeTo > 0, "the office is still closing pods");
            const pods = page.gridFor(Math.max(6, Math.ceil(48 / 8) + 1)).pods;
            compare(page.closeTo, pods, "down to what the new view needs");
            runUntil(() => !page.closeTo, 6000, "the office shrinks");
            compare([page.world.across, page.world.pods.length], [page.gridFor(pods).across, pods]);
            for (let i = 0; i < 40; i++)
                verify(page.world.seatOf["t" + i] !== undefined && page.world.seatOf["t" + i].pod < pods, "t" + i + " has a desk");
            checkFloor();
            for (const id of Object.keys(page.game.actors)) {
                const seat = page.world.seatOf[id];
                runUntil(() => arrived(actor(id)) && actor(id).tx === seat.x && actor(id).ty === seat.y, 3000, id + " gets to its desk");
            }
            checkFloor();
        }

        // Someone resting at its desk that a resize leaves where it sits
        // rests on to the same moment, so resizing never puts a break off;
        // one it moves rests 15 to 45 seconds from when it sits again.
        function test_a_resize_keeps_the_rest_of_someone_still_at_its_desk() {
            // Sixteen fill the first two pods. Going from three pods to a row
            // to two keeps the first pod where it is and moves the second
            // down a row.
            const people = many(16, "t", "waiting");
            plugin.publish(people);
            for (const p of people)
                actor(p.id).restless = 0;
            runUntil(() => people.every(p => arrived(actor(p.id)) && actor(p.id).until !== Infinity), 1500, "everyone sits and rests");
            compare(page.world.across, 3);
            const before = {};
            for (const p of people)
                before[p.id] = [actor(p.id).tx, actor(p.id).ty, actor(p.id).until];
            const stay = people.filter(p => page.world.seatOf[p.id].pod === 0);
            const move = people.filter(p => page.world.seatOf[p.id].pod === 1);
            compare([stay.length, move.length], [8, 8], "eight sit in each of the first two pods");
            resize(700, 1000);
            compare(page.world.across, 2, "the office takes two pods to a row");
            for (const p of stay) {
                const a = actor(p.id), seat = page.world.seatOf[p.id];
                compare([seat.x, seat.y, a.tx, a.ty], before[p.id].slice(0, 2).concat(before[p.id].slice(0, 2)), p.id + " keeps its desk and sits at it");
                verify(arrived(a), p.id + " still sits");
                compare(a.until, before[p.id][2], p.id + " rests on to the same moment");
            }
            const sat = {};
            for (const p of move) {
                const seat = page.world.seatOf[p.id];
                verify(seat.x !== before[p.id][0] || seat.y !== before[p.id][1], p.id + " has a desk somewhere else");
                compare(actor(p.id).until, Infinity, p.id + " rests only once it sits again");
            }
            // Each that moves rests 15 to 45 seconds from the tick it sits.
            runUntil(() => {
                for (const p of move) {
                    const a = actor(p.id);
                    if (sat[p.id] || a.until === Infinity)
                        continue;
                    verify(arrived(a) && a.tx === page.world.seatOf[p.id].x && a.ty === page.world.seatOf[p.id].y, p.id + " rests only at its new desk");
                    verify(a.until - page.game.now >= 15000 && a.until - page.game.now <= 45000, p.id + " rests 15 to 45 seconds, not " + (a.until - page.game.now));
                    sat[p.id] = true;
                }
                for (const p of stay)
                    compare(actor(p.id).until, before[p.id][2], p.id + " rests on to the same moment");
                return move.every(p => sat[p.id]);
            }, 1500, "everyone who moves sits again");
        }

        // A resize that keeps the office's grid still works out again how
        // many pods a closing office closes down to, for the new view.
        function test_a_resize_that_keeps_the_grid_retargets_a_closure() {
            resize(1150, 900);
            plugin.publish(many(70, "t", "working", "typing"));
            walk(200);
            compare([page.world.across, page.world.pods.length], [4, 12]);
            plugin.publish(many(40, "t", "working", "typing"));
            compare(page.closeTo, 9, "40 people close the office down to nine pods");
            const world = page.world;
            resize(1450, 900);
            compare(page.gridFor(12).across, 4, "the wider view keeps the office's grid");
            verify(page.world === world, "so the office is not built again");
            compare(page.closeTo, 8, "but it closes down to eight pods, as the wider view fits best");
            runUntil(() => !page.closeTo, 6000, "the office shrinks");
            compare(page.world.pods.length, 8);
            checkFloor();
        }

        // Someone listening at a desk in a pod the office closes stays for the
        // talk, then goes to its new desk; the pod closes after, and no tile
        // stays claimed for the talk or past the office's new end.
        function test_a_listener_in_a_closing_pod_finishes_the_talk() {
            resize(1200, 760);
            const all = many(70, "t", "working", "typing");
            plugin.publish(all);
            runUntil(() => page.moves === 0, 6000, "every desk is in");
            compare(page.world.pods.length, 12);
            const listener = all.find(p => page.world.seatOf[p.id].pod >= 9);
            verify(listener, "someone sits in a pod a smaller office would close");
            const speaker = all.find(p => page.world.seatOf[p.id].pod < 9);
            const stay = all.filter(p => page.world.seatOf[p.id].pod < 9).slice(0, 55).concat([listener]);
            verify(stay.includes(listener) && stay.length === 56, "56 people stay, the listener among them");
            const talks = [
                {
                    id: "talk-1",
                    from: speaker.id,
                    to: listener.id,
                    kind: "message",
                    text: "Got a minute?",
                    at: new Date().toISOString()
                }
            ];
            plugin.publish(all, talks);
            const s = actor(speaker.id), l = actor(listener.id);
            runUntil(() => s.talk?.phase === "say", 3000, "the talk starts");
            const W = page.world.cols, held = l.ty * W + l.tx;
            compare(l.hold, held, "the listener holds the tile it listens on");
            checkFloor();
            plugin.publish(stay, talks);
            compare(page.closeTo, 9, "the office closes the pods past nine");
            verify(page.world.seatOf[listener.id].pod < 9, "the listener has a desk in a pod that stays");
            let ended = false;
            runUntil(() => {
                checkFloor();
                if (s.talk)
                    compare(page.game.claims[held], listener.id, "the listener keeps its tile while it listens");
                else
                    ended = true;
                return ended && !page.closeTo;
            }, 6000, "the talk ends and the office shrinks");
            compare(page.world.pods.length, 9);
            compare([l.hold, l.heldBy], [-1, ""], "nothing is held for the talk");
            const tiles = page.world.cols * page.world.rows;
            const mine = Object.values(page.game.actors).map(p => p.claim);
            for (const tile of Object.keys(page.game.claims)) {
                verify(Number(tile) < tiles, "tile " + tile + " is past the office's end");
                verify(mine.includes(Number(tile)), "tile " + tile + " is claimed by " + page.game.claims[tile] + ", who stops elsewhere");
            }
            const seat = page.world.seatOf[listener.id];
            runUntil(() => {
                checkFloor();
                return arrived(l) && l.tx === seat.x && l.ty === seat.y;
            }, 3000, "the listener gets to its new desk");
        }

        // Movers may carry out the desk someone listens at, the last in the
        // pods the office closes, before it replies; the office waits for the
        // talk before it closes them.
        function test_the_office_closes_a_pod_only_once_its_talks_are_over() {
            resize(1200, 760);
            const all = many(70, "t", "working", "typing");
            plugin.publish(all);
            runUntil(() => page.moves === 0, 6000, "every desk is in");
            compare(page.world.pods.length, 12);
            const listener = all.find(p => page.world.seatOf[p.id].pod >= 9);
            const speaker = all.find(p => page.world.seatOf[p.id].pod < 9);
            const stay = all.filter(p => page.world.seatOf[p.id].pod < 9).slice(0, 55).concat([listener]);
            const talks = [
                {
                    id: "talk-1",
                    from: speaker.id,
                    to: listener.id,
                    kind: "message",
                    text: "Got a minute?",
                    at: new Date().toISOString()
                }
            ];
            plugin.publish(all, talks);
            const s = actor(speaker.id), l = actor(listener.id);
            runUntil(() => s.talk?.phase === "say", 3000, "the talk starts");
            const W = page.world.cols, held = l.ty * W + l.tx;
            // The speaker goes on until it is let go.
            s.talk.until = Infinity;
            plugin.publish(stay, talks);
            compare(page.closeTo, 9);
            const first = 9 * page.world.pods[0].seats.length;
            const closing = page.world.seats.slice(first);
            runUntil(() => closing.every(seat => seat.state === "out" && !seat.mover), 6000, "the movers carry out every desk in the closing pods");
            page.game.advance(50);
            compare([page.world.pods.length, page.closeTo], [12, 9], "the office waits for the talk");
            compare([s.talk?.phase, l.hold, page.game.claims[held]], ["say", held, listener.id], "the listener listens on where it was");
            s.talk.until = page.game.now;
            runUntil(() => !s.talk && !page.closeTo, 1500, "the talk ends and the office shrinks");
            compare(page.world.pods.length, 9);
            const seat = page.world.seatOf[listener.id];
            runUntil(() => arrived(l) && l.tx === seat.x && l.ty === seat.y, 3000, "the listener gets to its new desk");
        }

        // Someone listening on the floor in the rows a shorter office loses
        // keeps the office from shrinking until the talk is over, as one
        // listening at a closing desk does.
        function test_the_office_shrinks_only_once_nobody_listens_where_it_ends() {
            resize(900, 900);
            compare([page.gridFor(12).across, page.gridFor(9).across], [3, 3], "the office keeps three pods to a row as it shrinks");
            const all = many(70, "t", "working", "typing");
            plugin.publish(all);
            runUntil(() => page.moves === 0, 6000, "every desk is in");
            compare([page.world.across, page.world.pods.length], [3, 12]);
            const end = page.officeRows(3) - 1;
            const listener = all.find(p => page.world.seatOf[p.id].pod >= 9);
            const speaker = all.find(p => page.world.seatOf[p.id].pod < 9);
            const stay = all.filter(p => page.world.seatOf[p.id].pod < 9).slice(0, 55).concat([listener]);
            // The listener stands on the floor past where the shorter office ends.
            const l = actor(listener.id), s = actor(speaker.id);
            let x = 1, y = end + 1;
            while (!(page.game.walkable(x, y) && page.game.plan().grid[y * page.world.cols + x] === 0 && page.game.claims[y * page.world.cols + x] === undefined)) {
                if (++x >= page.world.xd) {
                    x = 1;
                    y++;
                }
            }
            verify(y < page.world.rows - 1, "there is floor in the rows the office loses");
            standAt(l, x, y);
            runUntil(() => arrived(l), 1500, "the listener stands there");
            const talks = [
                {
                    id: "talk-1",
                    from: speaker.id,
                    to: listener.id,
                    kind: "message",
                    text: "Got a minute?",
                    at: new Date().toISOString()
                }
            ];
            plugin.publish(all, talks);
            runUntil(() => s.talk?.phase === "say", 3000, "the talk starts");
            const held = y * page.world.cols + x;
            compare([l.tx, l.ty, l.hold], [x, y, held], "the listener listens on the floor there");
            s.talk.until = Infinity;
            plugin.publish(stay, talks);
            compare(page.closeTo, 9);
            const closing = page.world.seats.slice(9 * page.world.pods[0].seats.length);
            runUntil(() => closing.every(seat => seat.state === "out" && !seat.mover), 6000, "the movers carry out every desk in the closing pods");
            page.game.advance(50);
            compare([page.world.pods.length, page.closeTo], [12, 9], "the office waits for the talk");
            compare([s.talk?.phase, l.tx, l.ty, l.hold, page.game.claims[held]], ["say", x, y, held, listener.id], "the listener listens on where it was");
            s.talk.until = page.game.now;
            runUntil(() => !s.talk && !page.closeTo, 1500, "the talk ends and the office shrinks");
            compare(page.world.pods.length, 9);
            const seat = page.world.seatOf[listener.id];
            runUntil(() => arrived(l) && l.tx === seat.x && l.ty === seat.y, 3000, "the listener gets to its new desk");
        }

        // A resize that keeps the same best grid leaves the office as it is.
        function test_a_resize_that_keeps_the_grid_keeps_the_office() {
            resize(1600, 900);
            plugin.publish(many(70, "t", "working", "typing"));
            walk(20);
            wait(50);
            const world = page.world, paints = page.floorPaints;
            const at = Object.keys(page.game.actors).map(id => [actor(id).px, actor(id).py]);
            resize(1700, 950);
            resize(1550, 880);
            verify(page.world === world, "the office is not built again");
            wait(50);
            compare(page.floorPaints, paints, "nor painted again");
            compare(Object.keys(page.game.actors).map(id => [actor(id).px, actor(id).py]), at, "nobody moves");
        }

        // Reviewers fill the review corner without the office growing; those
        // past its eight desks need ordinary ones.
        function test_the_office_grows_for_reviewers_only_past_the_corner() {
            const reviewers = n => {
                const list = [];
                for (let i = 0; i < n; i++)
                    list.push(reviewer("r" + i, "Review " + i));
                return list;
            };
            plugin.publish(many(40, "t", "working", "typing").concat(reviewers(8)));
            compare(page.world.seats.length, 48, "40 people and 8 reviewers fit in six pods");
            plugin.publish(many(40, "t", "working", "typing").concat(reviewers(9)));
            verify(page.world.seats.length > 48, "a ninth reviewer takes an ordinary desk");
            walk(100);
        }

        // A worker at an ordinary desk whose lead turns out to be a reviewer
        // keeps that desk, so the office counts it among the ordinary ones.
        function test_a_reviewer_at_an_ordinary_desk_counts_as_one() {
            const others = many(39, "t", "working", "typing");
            plugin.publish(others.concat([person("w", "W", "working", "typing", "lead")]));
            const floor = page.world.seatOf["w"];
            verify(!page.world.pods[floor.pod].review, "W sits at an ordinary desk");
            plugin.publish(others.concat([reviewer("lead", "Lead"), reviewer("w", "W", "lead")]));
            compare(page.world.seatOf["w"], floor, "W keeps its desk");
            plugin.publish(others.concat([reviewer("lead", "Lead"), reviewer("w", "W", "lead"), person("t39", "t 39", "working", "typing")]));
            for (const id of Object.keys(page.game.actors))
                verify(page.world.seatOf[id] !== undefined, id + " has a desk");
            walk(200);
        }

        // People going in and out of the rows an office is closing keep to
        // the floor, and those on their way when it shrinks go on from the
        // nearest floor of the smaller office.
        function test_people_and_movers_carry_on_when_the_office_shrinks() {
            plugin.publish(many(75, "t", "working", "typing"));
            walk(200);
            plugin.publish(many(30, "t", "working", "typing"));
            compare(page.closeTo, 6);
            walk(4000);
            compare([page.world.pods.length, page.game.rows], [6, 19]);
            compare(page.closeTo, 0);
            runUntil(() => Object.keys(page.crew.members).length === 0 && page.jobs.length === 0, 4000, "the movers are done");
            for (const id of Object.keys(page.game.actors))
                runUntil(() => arrived(actor(id)), 1500, id + " gets where it is going");
        }

        // An office that empties before its new desks arrive closes the pods
        // at once: there is nothing to carry out, and with nobody in it the
        // clock may not run again.
        function test_an_office_emptied_before_its_desks_arrive_closes_at_once() {
            plugin.publish([]);
            plugin.publish(many(75, "t", "working", "typing"));
            verify(page.world.pods.length > 6, "75 people need more pods");
            plugin.publish([]);
            compare(page.closeTo, 0, "no closure is left pending");
            compare([page.world.pods.length, page.game.rows], [6, 19], "the office is back to six pods");
        }

        function test_a_break_lasts_from_when_the_person_gets_there() {
            const people = many(20, "t", "working", "typing");
            plugin.publish(people);
            const resting = people.slice(0, 8).map(p => person(p.id, p.title, "waiting"));
            plugin.publish(resting.concat(people.slice(8)));
            for (const p of resting)
                page.takeBreak(actor(p.id));
            const first = {}, since = {};
            runUntil(() => {
                let done = 0;
                for (const p of resting) {
                    const a = actor(p.id);
                    first[p.id] = first[p.id] ?? a.goal;
                    if (since[p.id] === undefined) {
                        if (arrived(a))
                            since[p.id] = page.game.now;
                    } else if (page.game.now - since[p.id] >= 3000) {
                        done++;
                    } else {
                        verify(a.goal === first[p.id], p.id + " left its break spot " + (page.game.now - since[p.id]) + " ms after getting there");
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

        // Where a row of open floor with open rows above and below it starts,
        // with nobody standing on it.
        function openFloor(length) {
            const w = page.world;
            const taken = {};
            for (const a of Object.values(page.game.actors))
                taken[a.ty * w.cols + a.tx] = true;
            for (let y = 1; y < w.rows - 1; y++) {
                for (let x = 0; x + length <= w.cols; x++) {
                    let open = true;
                    for (let dx = 0; dx < length && open; dx++) {
                        for (let dy = -1; dy <= 1; dy++)
                            open = open && page.game.walkable(x + dx, y + dy) && !taken[(y + dy) * w.cols + x + dx] && !page.game.claims[(y + dy) * w.cols + x + dx];
                    }
                    if (open)
                        return [x, y];
                }
            }
            fail("the office has open floor");
        }

        // Runs the office until `a` and `b` get where they are going, and
        // returns the ticks that took; each walks a straight row, so it took
        // no longer than walking it alone, stopping for nobody.
        function walkBoth(a, b, tiles) {
            let ticks = 0, crossed = false;
            while (ticks < 600 && !(arrived(a) && arrived(b))) {
                walk(1);
                ticks++;
                crossed = crossed || Math.abs(a.px - b.px) < 16 && a.py === b.py;
            }
            verify(ticks <= tiles * 8 + 2, "both walk straight on, in " + ticks + " ticks");
            return crossed;
        }

        // A person walks through someone standing in its way rather than
        // waiting for it, or going around; it never stops there.
        function test_a_person_walks_through_someone_standing_in_its_way() {
            plugin.publish([person("a", "A", "working", "typing"), person("b", "B", "working", "typing")]);
            const a = actor("a"), b = actor("b");
            const [left, row] = openFloor(5);
            standAt(b, left + 2, row);
            standAt(a, left, row);
            send(a, left + 4, row);
            let through = false;
            for (let i = 0; i < 4 * 8 + 2 && !arrived(a); i++) {
                walk(1);
                through = through || a.tx === b.tx && a.ty === b.ty;
            }
            verify(through, "A walks across B's tile");
            compare([a.tx, a.ty], [left + 4, row], "A gets where it is going, as fast as on open floor");
            compare([b.tx, b.ty, b.next], [left + 2, row, -1], "B never moves");
        }

        // Two people walking into each other, or swapping places, walk through
        // each other: neither steps aside, waits or goes around.
        function test_two_people_walking_into_each_other_walk_through() {
            plugin.publish([person("a", "A", "working", "typing"), person("b", "B", "working", "typing")]);
            const a = actor("a"), b = actor("b");
            const [left, row] = openFloor(8);
            for (const [aFrom, aTo, bFrom, bTo] of [[left + 3, left + 7, left + 4, left], [left + 1, left + 2, left + 2, left + 1]]) {
                standAt(a, aFrom, row);
                standAt(b, bFrom, row);
                send(a, aTo, row);
                send(b, bTo, row);
                verify(walkBoth(a, b, Math.max(Math.abs(aTo - aFrom), Math.abs(bTo - bFrom))), "they pass through each other");
                compare([a.tx, a.ty, b.tx, b.ty], [aTo, row, bTo, row], "both get where they are going");
            }
        }

        // A person and a mover carrying a desk that meet head-on walk through
        // each other, as two people do: neither steps aside, waits or goes
        // around.
        function test_a_person_and_a_mover_walk_through_each_other() {
            plugin.publish(many(4, "t", "working", "typing"));
            plugin.publish(many(5, "t", "working", "typing"));
            runUntil(() => Object.keys(page.crew.members).length > 0, 400, "a mover comes in");
            const m = Object.values(page.crew.members)[0];
            const key = m.key;
            verify(m.carrying, "it carries a desk");
            // It carries the desk along open floor instead of to its seat.
            page.world.seats[m.job].mover = "";
            m.job = -1;
            m.path = [];
            const a = actor("t0");
            const [left, row] = openFloor(6);
            standAt(a, left + 5, row);
            m.place(left, row, true);
            m.goal = {
                x: left + 5,
                y: row,
                face: 0,
                offY: 0,
                pose: "stand",
                kind: "leave"
            };
            m.route();
            send(a, left, row);
            let ticks = 0, crossed = false, aside = false;
            while (ticks < 600 && (page.crew.members[key] || !arrived(a))) {
                walk(1);
                ticks++;
                aside = aside || a.ty !== row || page.crew.members[key] && m.ty !== row;
                crossed = crossed || page.crew.members[key] && Math.abs(a.px - m.px) < 16 && a.py === m.py;
            }
            verify(crossed, "they pass through each other");
            verify(!aside, "neither steps off the row");
            verify(ticks <= 5 * 8 + 2, "both walk straight on, in " + ticks + " ticks");
            verify(!page.crew.members[key], "the mover gets where it is going");
            compare([a.tx, a.ty], [left, row], "and so does the person");
        }

        // Where two people both want to stop, only one may: the tile is the
        // first one's, and the other stops beside it.
        function test_two_people_never_stop_on_one_tile() {
            plugin.publish(many(16, "t", "working", "typing"));
            checkFloor();
            const people = many(16, "t", "waiting");
            plugin.publish(people);
            // More than the break room has places for go at once.
            for (const id of Object.keys(page.game.actors))
                page.takeBreak(actor(id));
            const stops = {};
            for (const id of Object.keys(page.game.actors)) {
                const g = actor(id).goal;
                const key = g.x + "," + g.y;
                verify(stops[key] === undefined, id + " and " + stops[key] + " both stop at " + key);
                stops[key] = id;
            }
            walk(400);
        }

        function test_what_a_person_does_follows_its_agent() {
            const lead = person("lead", "Lead", "working", "typing");
            plugin.publish([lead]);
            runUntil(() => arrived(actor("lead")));
            compare(actor("lead").goal.kind, "desk");
            page.game.advance(7);
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

        // A waiting or idle person stays at its desk, and now and then, by its
        // own restlessness, takes a short break and comes back.
        function test_waiting_people_stay_at_their_desks_and_now_and_then_take_a_break() {
            plugin.publish([person("lead", "Lead", "working", "typing"), person("calm", "Calm", "working", "typing")]);
            runUntil(() => arrived(actor("lead")) && arrived(actor("calm")));
            const desk = [actor("lead").tx, actor("lead").ty];

            plugin.publish([person("lead", "Lead", "waiting"), person("calm", "Calm", "idle")]);
            for (const id of ["lead", "calm"]) {
                compare(actor(id).goal.kind, "desk", id + " stays at its desk");
                compare(actor(id).plan, "rest");
            }
            page.game.advance(1);
            compare(actor("lead").frame, page.frame.sit, "the lead sits back");
            actor("lead").restless = 1;
            actor("calm").restless = 0;
            runUntil(() => arrived(actor("lead")) && actor("lead").tx > page.world.xd, 2500, "the lead gets up for a break");
            runUntil(() => arrived(actor("lead")) && actor("lead").plan === "rest", 2500, "the lead comes back");
            compare([actor("lead").tx, actor("lead").ty], desk);
            const calm = actor("calm");
            compare(calm.goal.kind, "desk", "someone never restless never leaves its desk");
            compare(calm.plan, "rest");

            plugin.publish([person("lead", "Lead", "working", "typing"), person("calm", "Calm", "idle")]);
            compare(actor("lead").goal.kind, "desk");
            compare(actor("lead").cup, false, "back to work, the cup is put away");
        }

        // With 70 people waiting, most stay at their desks, and the break room
        // never holds more than its cap.
        function test_the_break_room_never_holds_more_than_its_cap() {
            const people = many(70, "t", "waiting");
            plugin.publish(people);
            for (const id of Object.keys(page.game.actors))
                actor(id).restless = 1;
            let most = 0;
            for (let i = 0; i < 3000; i++) {
                page.game.advance(1);
                let away = 0, inside = 0;
                for (const id of Object.keys(page.game.actors)) {
                    if (actor(id).plan === "break")
                        away++;
                    if (actor(id).tx > page.world.xd)
                        inside++;
                }
                verify(away <= page.breakRoomCap, away + " on a break");
                verify(inside <= page.breakRoomCap, inside + " in the break room");
                most = Math.max(most, away);
                if (i % 50 === 0)
                    checkFloor();
            }
            compare(most, page.breakRoomCap, "the break room fills up to its cap");
        }

        // Someone whose break is over still fills the break room until it
        // walks out, so nobody else gets in meanwhile.
        function test_a_place_in_the_break_room_is_kept_until_its_taker_leaves() {
            const people = many(9, "t", "waiting");
            plugin.publish(people);
            runUntil(() => people.every(p => arrived(actor(p.id))), 2500, "everyone sits down");
            const away = people.slice(0, page.breakRoomCap).map(p => actor(p.id));
            for (const a of away) {
                page.takeBreak(a);
                a.stay = 1e9;
            }
            runUntil(() => away.every(a => arrived(a)), 2500, "the break room fills up");
            const first = away[0];
            runUntil(() => {
                if (first.plan === "break" && first.until !== Infinity)
                    first.until = page.game.now;
                return first.plan === "rest";
            }, 200, "a break ends");
            verify(first.tx > page.world.xd, "it is still in the break room");
            const last = actor(people[page.breakRoomCap].id);
            last.restless = 1;
            page.restless(last);
            compare(last.plan, "rest", "nobody else gets in while it is still there");
            runUntil(() => first.tx <= page.world.xd, 1500, "it walks out");
            page.restless(last);
            compare(last.plan, "break", "then there is room again");
        }

        // People differ: over the same time, some take breaks and others
        // don't, and the ones that do go to different places. A break is
        // counted once, however many places it takes in (coffee, then the
        // couch); every place goes towards the variety.
        function test_breaks_come_at_random_per_person() {
            plugin.publish(many(40, "t", "idle"));
            const breaks = {}, plans = {}, goals = {}, kinds = {};
            for (let i = 0; i < 6000; i++) {
                page.game.advance(1);
                for (const id of Object.keys(page.game.actors)) {
                    const a = actor(id);
                    if (a.plan === "break" && plans[id] !== "break")
                        breaks[id] = (breaks[id] ?? 0) + 1;
                    plans[id] = a.plan;
                    if (a.plan === "break" && a.goal && a.goal !== goals[id])
                        kinds[a.goal.kind] = true;
                    goals[id] = a.goal;
                }
            }
            const counts = Object.keys(page.game.actors).map(id => breaks[id] ?? 0);
            verify(counts.some(n => n === 0), "someone stayed at its desk");
            verify(counts.some(n => n >= 2), "someone took more than one break");
            verify(new Set(counts).size >= 3, "how often differs");
            verify(["coffee", "cooler", "couch", "table", "arcade", "chat", "vending", "fridge", "armchair"].filter(k => kinds[k]).length >= 4, "breaks go to different places");
        }

        // Every slacking frame fits on the 8×6 screen in the six blocks a
        // screen has for it.
        function test_every_slacking_frame_fits_on_a_screen() {
            for (const name of Object.keys(page.slackArt)) {
                const art = page.slackArt[name];
                verify(art.frames.length >= 2, name + " has frames to change between");
                for (const frame of art.frames) {
                    verify(frame.length >= 1 && frame.length <= 6, name + " has one to six blocks a frame");
                    for (const [x, y, w, h] of frame)
                        verify(x >= 0 && y >= 0 && w > 0 && h > 0 && x + w <= 8 && y + h <= 6, name + " stays on the screen");
                }
            }
        }

        // Waiting people slack off on their screens most of the time, idle
        // ones now and then, each picking at random and changing every so
        // often; working people keep to their work, and a screen changes at
        // most once a second.
        function test_waiting_people_slack_off_on_their_screens() {
            const people = many(24, "w", "waiting").concat(many(24, "i", "idle"), many(8, "k", "working", "typing"));
            plugin.publish(people);
            const seen = {}, picks = {}, last = {};
            const on = {
                w: 0,
                i: 0
            }, at = {
                w: 0,
                i: 0
            };
            for (let t = 0; t < 1500; t++) {
                page.game.advance(1);
                const screens = viewsIn(page.screenViews);
                for (const p of people) {
                    const seat = page.world.seatOf[p.id];
                    const view = seat && screens[seat.screen];
                    if (!view || view.mode === "off") {
                        delete last[p.id];
                        continue;
                    }
                    const kind = p.id[0];
                    if (kind === "k") {
                        compare(view.slack, "", p.id + " keeps to its work");
                        continue;
                    }
                    // A frame that follows another frame of the same slacking
                    // was up for a second; the first after a pick may be shorter.
                    const was = last[p.id];
                    if (was && (was.slack !== view.slack || was.scene !== view.scene)) {
                        const next = was.slack === view.slack;
                        if (next && was.frame)
                            verify(page.game.ticks - was.since >= 24, p.id + "'s screen changes at most once a second");
                        last[p.id] = {
                            slack: view.slack,
                            scene: view.scene,
                            since: page.game.ticks,
                            frame: next
                        };
                    } else if (!was) {
                        last[p.id] = {
                            slack: view.slack,
                            scene: view.scene,
                            since: page.game.ticks,
                            frame: false
                        };
                    }
                    at[kind]++;
                    if (view.slack) {
                        on[kind]++;
                        seen[view.slack] = true;
                        picks[p.id] = Object.assign(picks[p.id] ?? {}, {
                            [view.slack]: true
                        });
                    }
                }
            }
            compare(Object.keys(seen).sort(), Object.keys(page.slackArt).sort(), "every kind of slacking shows up");
            verify(Object.keys(picks).some(id => Object.keys(picks[id]).length >= 2), "someone switches to something else");
            const waiting = on.w / at.w, idle = on.i / at.i;
            verify(waiting > 0.5 && waiting < 0.95, "waiting people mostly slack, but not always: " + waiting);
            verify(idle > 0.1 && idle < waiting, "idle people slack less: " + idle);
        }

        // Someone asking the user something keeps its screen on the question.
        function test_a_person_asking_does_not_slack_off() {
            plugin.publish(many(16, "a", "asking"));
            for (let t = 0; t < 600; t++) {
                page.game.advance(1);
                for (const view of Object.values(viewsIn(page.screenViews)))
                    compare(view.slack, "");
            }
        }

        // A person slacking while it waits drops it as soon as its agent asks
        // something, or gets to work, even with nothing in particular to do.
        function test_slacking_stops_as_soon_as_the_state_changes_data() {
            return [
                {
                    tag: "asking",
                    state: "asking"
                },
                {
                    tag: "working with no activity",
                    state: "working"
                }
            ];
        }

        function test_slacking_stops_as_soon_as_the_state_changes(data) {
            plugin.publish(many(16, "a", "waiting"));
            let slacking = 0;
            for (let t = 0; t < 300; t++) {
                page.game.advance(1);
                slacking += Object.values(viewsIn(page.screenViews)).filter(view => view.slack).length;
            }
            verify(slacking > 0, "they slack off while waiting");
            plugin.publish(many(16, "a", data.state));
            page.game.advance(5);
            for (let t = 0; t < 600; t++) {
                for (const view of Object.values(viewsIn(page.screenViews)))
                    compare(view.slack, "", data.tag + " people do not slack");
                page.game.advance(1);
            }
        }

        // While nobody walks the clock ticks slower, and a slacking frame still
        // lasts a second.
        function test_a_slacking_frame_lasts_a_second_on_the_slow_clock() {
            plugin.publish(many(24, "w", "waiting"));
            runUntil(() => !page.game.walking, 4000, "everyone sits down");
            const last = {};
            let changes = 0;
            for (let t = 0; t < 600; t++) {
                page.game.tick(200);
                for (const [key, view] of Object.entries(viewsIn(page.screenViews))) {
                    const was = last[key];
                    if (was && view.slack && was.slack === view.slack && was.scene !== view.scene) {
                        if (was.changed)
                            compare(page.game.now - was.at, 1000, "a frame is up for a second");
                        changes++;
                        last[key] = {
                            slack: view.slack,
                            scene: view.scene,
                            at: page.game.now,
                            changed: true
                        };
                    } else if (!was || was.slack !== view.slack) {
                        last[key] = {
                            slack: view.slack,
                            scene: view.scene,
                            at: page.game.now,
                            changed: false
                        };
                    }
                }
            }
            verify(changes > 50, "frames change: " + changes);
        }

        function test_a_bubble_is_over_anothers_icon() {
            const people = [person("lead", "Lead", "working", "typing"), person("rev", "Reviewer", "working", "typing"), person("ask", "Fix the parser", "asking")];
            plugin.publish(people);
            runUntil(() => people.every(each => arrived(actor(each.id))));
            plugin.publish(people, [
                {
                    id: "talk-over",
                    from: "lead",
                    to: "rev",
                    kind: "message",
                    text: "Please look at the diff",
                    at: new Date().toISOString()
                }
            ]);
            runUntil(() => actor("lead").talk?.phase === "say", 2000, "the speaker walks up");
            page.game.advance(1);
            const speaker = find("officeBubble:lead").parent;
            let other = find("officeIcon:ask");
            while (other && other.parent !== speaker.parent)
                other = other.parent;
            verify(other, "both are over the room");
            verify(speaker.z > other.z, "a bubble's " + speaker.z + " is over an icon's " + other.z);
        }

        function test_the_wall_between_the_rooms_has_no_hole() {
            plugin.publish([person("one", "One", "working", "typing")]);
            tryVerify(() => page.settled);
            waitForRendering(loader.item);
            const x = page.world.xd * 16 + 8, ctx = find("officeFloor").getContext("2d");
            for (let y = 0; y < 5 * 16; y++)
                compare(ctx.getImageData(x, y, 1, 1).data[3], 255, "painted at y " + y);
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
            page.game.advance(1);
            const a = actor("lead"), b = actor("rev");
            compare(Math.abs(a.tx - b.tx) + Math.abs(a.ty - b.ty), 1);
            compare(a.dir, page.game.talks.towards(a, b));
            compare(b.face, page.game.talks.towards(b, a));
            const bubble = find("officeBubble:lead");
            verify(bubble.visible);
            compare(actor("lead").bubble, "Please look at the diff");

            runUntil(() => actor("lead").talk === null, 400, "the talk ends");
            verify(!bubble.visible);
            runUntil(() => arrived(actor("lead")) && actor("lead").goal.kind === "desk", 2000, "the speaker goes back to work");
        }

        function test_a_talk_heard_before_both_are_in_the_office_waits_for_them_data() {
            return [
                {
                    tag: "the listener comes after",
                    late: "worker"
                },
                {
                    tag: "the speaker comes after",
                    late: "lead"
                }
            ];
        }

        // A hand-off heard before its worker is named is "…" until the office knows.
        function test_a_talk_takes_the_text_the_office_has_for_it_now() {
            const people = many(4, "t", "working", "typing");
            const said = (first, second) => [
                Object.assign(message_to("first", "t0", "t1"), { text: first }),
                Object.assign(message_to("second", "t0", "t2"), { text: second })
            ];
            plugin.publish(people);
            plugin.publish(people, said("…", "…"));
            page.game.advance(1);
            const a = actor("t0");
            compare(a.talk?.text, "…", "the first is on its way over");
            compare(a.queue.length, 1, "the second waits");
            plugin.publish(people, said("Fix the\nparser", "Write the tests"));
            compare(a.talk.text, "Fix the parser", "the one walking over takes it");
            compare(a.queue[0].text, "Write the tests", "so does the one waiting");
            runUntil(() => a.talk?.phase === "say", 2000, "the first is said");
            page.game.advance(1);
            compare(actor("t0").bubble, "Fix the parser");
            plugin.publish(people, said("Fix the lexer", "Write the tests"));
            page.game.advance(1);
            compare(actor("t0").bubble, "Fix the lexer", "so does the one being said");
        }

        // A hand-off's call often ends before its worker's row reaches the office.
        function test_a_talk_heard_before_both_are_in_the_office_waits_for_them(data) {
            const both = [person("lead", "Lead", "working", "typing"), person("worker", "Worker", "working", "typing")];
            const early = both.filter(p => p.id !== data.late);
            const talks = [
                {
                    id: "delegate:worker",
                    from: "lead",
                    to: "worker",
                    kind: "delegate",
                    text: "Fix the parser",
                    at: new Date().toISOString()
                }
            ];
            plugin.publish(early);
            page.game.advance(25);
            plugin.publish(early, talks);
            page.game.advance(25);
            plugin.publish(both, talks);
            runUntil(() => actor("lead").talk?.phase === "say", 2000, "the talk waits for both");
            page.game.advance(1);
            compare(actor("lead").bubble, "Fix the parser");
            plugin.publish(both, talks);
            compare(actor("lead").queue.length, 0, "a talk is heard once");
        }

        // The MC ends a talk, by its own clock: the page never does by a talk's age.
        function test_a_talk_waits_as_long_as_the_office_has_it_whatever_its_age() {
            const lead = person("lead", "Lead", "working", "typing");
            const talks = [
                {
                    id: "delegate:worker",
                    from: "lead",
                    to: "worker",
                    kind: "delegate",
                    text: "Fix the parser",
                    at: new Date(Date.now() - 120000).toISOString()
                }
            ];
            plugin.publish([lead]);
            plugin.publish([lead], talks);
            plugin.publish([lead, person("worker", "Worker", "working", "typing")], talks);
            compare(actor("lead").queue.length, 1, "the talk waits as long as the topic keeps it");
        }

        function message_to(id, from, to) {
            return {
                id: id,
                from: from,
                to: to,
                kind: "message",
                text: id,
                at: new Date().toISOString()
            };
        }

        // The office shows what is happening, never what happened before it was looked at.
        function test_talks_there_when_the_office_opens_are_not_played() {
            const talks = [message_to("before", "t0", "t1"), message_to("early", "t0", "t2")];
            plugin.publish(many(2, "t", "working", "typing"), talks);
            compare(actor("t0").queue.length, 0, "a talk from before the page opened stays quiet");
            plugin.publish(many(3, "t", "working", "typing"), talks);
            compare(actor("t0").queue.length, 0, "also once its listener has come");
            plugin.publish(many(3, "t", "working", "typing"), talks.concat([message_to("now", "t0", "t1")]));
            runUntil(() => actor("t0").talk?.phase === "say", 2000, "a talk said now is played");
            compare(actor("t0").talk.text, "now");
        }

        function test_a_talk_still_waiting_when_the_office_drops_it_is_not_played() {
            const people = many(4, "t", "working", "typing");
            plugin.publish(people);
            plugin.publish(people, [message_to("first", "t0", "t1")]);
            page.game.advance(1);
            compare(actor("t0").talk?.text, "first");
            plugin.publish(people, [message_to("first", "t0", "t1"), message_to("second", "t0", "t2")]);
            compare(actor("t0").queue.length, 1, "the second waits for the first");
            plugin.publish(people, []);
            compare(actor("t0").queue.length, 0, "it is no longer what is happening");
            compare(actor("t0").talk?.text, "first", "the one under way goes on");
        }

        function test_an_office_shown_again_shows_what_is_happening_now() {
            plugin.publish(many(4, "t", "working", "typing"));
            plugin.publish(many(4, "t", "working", "typing"), [message_to("under way", "t0", "t1")]);
            page.game.advance(1);
            verify(actor("t0").talk, "a talk is under way as the page goes out of sight");
            // Ten minutes out of sight: most of a new team came, t3 left, and they talked.
            page.game.tickedAt = Date.now() - 600000;
            const people = many(3, "t", "working", "typing").concat(many(8, "n", "working", "typing"));
            plugin.publish(people, [message_to("meanwhile", "t2", "t1"), message_to("to new", "t1", "n0")]);
            verify(page.outside.length > 0 && page.moves > 0, "their coming in has piled up");
            page.inSight = true;
            tryVerify(() => Date.now() - page.game.tickedAt < 5000, 5000, "the clock runs again");
            page.inSight = false;
            compare(page.outside.length, 0, "nobody waits to walk in");
            compare(page.moves, 0, "nobody carries a desk");
            compare(page.deskCount, people.length, "the desks are those of the people here now");
            for (const p of people) {
                const a = actor(p.id);
                compare(a.talk, null, p.id + " plays no talk from before");
                compare(a.queue.length, 0, p.id + " has none waiting");
                compare(a.bubble, "", p.id + " says nothing old");
                verify(arrived(a), p.id + " is where it belongs");
            }
            checkFloor();
        }

        function test_a_talk_said_just_as_the_office_is_shown_again_is_played() {
            const people = many(3, "t", "working", "typing");
            plugin.publish(people);
            page.game.tickedAt = Date.now() - 600000;
            page.inSight = true;
            // Said before the clock's first tick.
            plugin.publish(people, [message_to("now", "t0", "t1")]);
            wait(300);
            page.inSight = false;
            const a = actor("t0");
            verify(a.talk || a.queue.length, "it is not taken for one from before");
            runUntil(() => a.talk?.phase === "say", 2000, "it is played");
            compare(a.talk.text, "now");
        }

        function test_a_glance_away_leaves_the_walks_and_talks_under_way() {
            plugin.publish(many(4, "t", "working", "typing"));
            plugin.publish(many(5, "t", "working", "typing"), [message_to("now", "t0", "t1")]);
            page.game.advance(1);
            page.game.tickedAt = Date.now() - 1000;
            page.inSight = true;
            tryVerify(() => Date.now() - page.game.tickedAt < 500, 5000, "the clock runs again");
            page.inSight = false;
            compare(actor("t0").talk?.text, "now");
            verify(page.moves > 0, "the new desk is still carried in");
        }

        function test_a_person_spoken_to_stops_to_listen_and_then_goes_on() {
            // Lead and C get the desks side by side.
            plugin.publish([person("lead", "Lead", "working", "typing"), person("b", "B", "working", "typing"), person("c", "C", "working", "typing")]);
            compare(Math.abs(actor("lead").tx - actor("c").tx) + Math.abs(actor("lead").ty - actor("c").ty), 1);
            // C heads for a break just as the lead speaks to it.
            plugin.publish([person("lead", "Lead", "working", "typing"), person("b", "B", "working", "typing"), person("c", "C", "waiting")]);
            page.takeBreak(actor("c"));
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
                page.game.advance(1);
            }
            verify(c.path.length > 0 || c.next >= 0, "C still knows where it was going");
            runUntil(() => arrived(c) && c.tx > page.world.xd, 2000, "C goes on to the break room");
        }

        // Someone spoken to on its way stops only where nobody else may, and the
        // speaker talks from the side it claimed, never where it happens to pass.
        function test_a_talk_stops_people_only_where_nobody_else_has_claimed() {
            plugin.publish([person("lead", "Lead", "working", "typing"), person("b", "B", "working", "typing"), person("c", "C", "working", "typing")]);
            plugin.publish([person("lead", "Lead", "working", "typing"), person("b", "B", "working", "typing"), person("c", "C", "waiting")]);
            page.takeBreak(actor("c"));
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
            const a = actor("lead"), c = actor("c");
            const W = page.world.cols;
            runUntil(() => a.talk?.met, 2000, "the lead catches C on its way");
            verify(c.path.length > 0 || c.next >= 0, "C is on its way");
            // Someone else has the tile C would stop at.
            const taken = c.next >= 0 ? c.next : c.ty * W + c.tx;
            page.game.claims[taken] = "b";
            runUntil(() => a.talk?.phase === "say", 4000, "the talk starts");
            verify(c.ty * W + c.tx !== taken, "C walks on past the spot that is someone else's");
            compare(page.game.claims[a.ty * W + a.tx], "lead", "the lead talks from the side it claimed");
            while (a.talk) {
                const here = c.ty * W + c.tx;
                if (c.next < 0)
                    verify(!page.game.claims[here] || page.game.claims[here] === "c", "C stands on a tile nobody else has");
                page.game.advance(1);
            }
            delete page.game.claims[taken];
            runUntil(() => arrived(c) && c.tx > page.world.xd, 2000, "C goes on to the break room");
        }

        // The one listening keeps the tile it stopped on for the whole talk:
        // anyone else looking for a spot, as every goal does, finds it taken,
        // so the listener stays put and the talk reaches its reply.
        function test_a_listener_keeps_its_tile_until_the_talk_ends() {
            plugin.publish([person("lead", "Lead", "working", "typing"), person("b", "B", "working", "typing"), person("c", "C", "working", "typing")]);
            plugin.publish([person("lead", "Lead", "working", "typing"), person("b", "B", "working", "typing"), person("c", "C", "waiting")]);
            page.takeBreak(actor("c"));
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
            const a = actor("lead"), b = actor("b"), c = actor("c");
            runUntil(() => a.talk?.phase === "say", 2000, "the talk starts");
            const spot = {
                x: c.tx,
                y: c.ty
            };
            const here = spot.y * page.world.cols + spot.x;
            // B looks for somewhere to stand and wants C's tile.
            if (page.game.free(spot, b)) {
                page.game.claim(b, spot);
                b.setGoal(Object.assign({
                    face: 0,
                    offY: 0,
                    pose: "stand",
                    kind: "spot"
                }, spot));
            }
            runUntil(() => a.talk?.phase === "reply", 400, "C replies");
            compare(page.game.claims[here], "c", "C holds the tile it listens on");
            verify(b.goal?.kind !== "spot", "B is not sent to C's tile");
            compare([c.tx, c.ty], [spot.x, spot.y], "C listens where it stopped");
            runUntil(() => !a.talk, 200, "the talk ends");
            verify(page.game.claims[here] === undefined || c.claim === here, "C lets go of the tile after the talk");
            runUntil(() => arrived(c) && c.tx > page.world.xd, 2000, "C goes on to the break room");
        }

        // A listener archived mid-talk leaves both tiles it held: the one it
        // listens on and the one it was headed for.
        function test_an_archived_listener_lets_go_of_its_tiles() {
            // Lead and C get the desks side by side, and C sets off for the
            // door just as the lead speaks to it.
            const people = [person("lead", "Lead", "working", "typing"), person("b", "B", "working", "typing"), person("c", "C", "working", "typing")];
            plugin.publish(people);
            const door = {
                x: page.world.entrance[0],
                y: page.world.entrance[1]
            };
            page.game.claim(actor("c"), door);
            actor("c").setGoal(Object.assign({
                face: 0,
                offY: 0,
                pose: "stand",
                kind: "spot"
            }, door));
            plugin.publish(people, [
                {
                    id: "talk-1",
                    from: "lead",
                    to: "c",
                    kind: "message",
                    text: "Got a minute?",
                    at: new Date().toISOString()
                }
            ]);
            const a = actor("lead"), c = actor("c");
            runUntil(() => a.talk?.phase === "say", 2000, "the talk starts");
            const here = c.ty * page.world.cols + c.tx, ahead = c.claim;
            compare(c.hold, here, "C holds the tile it listens on");
            verify(ahead >= 0 && ahead !== here, "and the one it was headed for");
            plugin.publish([person("lead", "Lead", "working", "typing"), person("b", "B", "working", "typing")]);
            verify(!actor("c"), "C has left");
            compare(page.game.claims[here], undefined, "C's tile is free");
            compare(page.game.claims[ahead], undefined, "the tile C was headed for is free");
            compare(Object.values(page.game.claims).indexOf("c"), -1, "C holds no tile at all");
            runUntil(() => !a.talk, 200, "the talk ends");
        }

        // A listener spoken to where it was headed keeps that tile for the
        // talk, even when it is sent elsewhere meanwhile.
        function test_a_listener_sent_elsewhere_keeps_its_tile_for_the_talk() {
            plugin.publish([person("lead", "Lead", "working", "typing"), person("c", "C", "working", "typing")]);
            const a = actor("lead"), c = actor("c");
            plugin.publish([person("lead", "Lead", "working", "typing"), person("c", "C", "waiting")]);
            runUntil(() => arrived(c) && c.tx > page.world.xd, 2000, "C gets to the break room");
            plugin.publish([person("lead", "Lead", "working", "typing"), person("c", "C", "waiting")], [
                {
                    id: "talk-1",
                    from: "lead",
                    to: "c",
                    kind: "message",
                    text: "Got a minute?",
                    at: new Date().toISOString()
                }
            ]);
            runUntil(() => a.talk?.phase === "say", 2000, "the talk starts");
            const here = c.ty * page.world.cols + c.tx;
            compare(c.claim, here, "C listens where it was headed");
            compare(c.hold, here, "and holds that tile for the talk");
            // C's agent gets to work: it is sent back to its desk.
            plugin.publish([person("lead", "Lead", "working", "typing"), person("c", "C", "working", "typing")]);
            c.decide(true);
            verify(c.claim !== here, "C is headed for its desk");
            while (a.talk) {
                compare(page.game.claims[here], "c", "C keeps the tile it listens on");
                compare([c.tx, c.ty], [here % page.world.cols, Math.floor(here / page.world.cols)], "C stays put");
                page.game.advance(1);
            }
            compare(page.game.claims[here], undefined, "C lets go of it after the talk");
            runUntil(() => arrived(c) && c.goal.kind === "desk", 2000, "C goes back to its desk");
        }

        // Two people with something to say to the same one take turns: the
        // second waits until the first is done.
        function test_two_speakers_take_turns_with_one_listener() {
            plugin.publish([person("lead", "Lead", "working", "typing"), person("d", "D", "working", "typing"), person("c", "C", "working", "typing")]);
            const a = actor("lead"), d = actor("d"), c = actor("c");
            const say = (from, id) => ({
                        id: id,
                        from: from,
                        to: "c",
                        kind: "message",
                        text: "From " + from,
                        at: new Date().toISOString()
                    });
            plugin.publish([person("lead", "Lead", "working", "typing"), person("d", "D", "working", "typing"), person("c", "C", "waiting")], [say("lead", "talk-1")]);
            runUntil(() => a.talk?.phase === "say", 2000, "the lead starts");
            plugin.publish([person("lead", "Lead", "working", "typing"), person("d", "D", "working", "typing"), person("c", "C", "waiting")], [say("lead", "talk-1"), say("d", "talk-2")]);
            let here = c.ty * page.world.cols + c.tx, turns = 0, last = "";
            for (let t = 0; t < 3000 && turns < 2; t++) {
                page.game.advance(1);
                const talking = [a, d].filter(p => p.talk?.to === "c");
                verify(talking.length <= 1, "one talks to C at a time");
                const now = talking[0];
                if (now && now.talk.phase !== "go") {
                    if (now.key !== last) {
                        last = now.key;
                        turns++;
                        here = c.ty * page.world.cols + c.tx;
                    }
                    compare(page.game.claims[here], "c", "C keeps its tile while " + now.key + " talks");
                }
            }
            compare(turns, 2, "both get their say");
            compare(last, "d", "D goes second");
        }

        // Two who talk to each other at once take turns: each is someone the
        // other talks to only once the first talk is over.
        function test_two_who_talk_to_each_other_take_turns() {
            const people = [person("a", "A", "working", "typing"), person("b", "B", "working", "typing")].concat(many(4, "o", "working", "typing"));
            plugin.publish(people);
            const a = actor("a"), b = actor("b");
            const say = (from, to, id) => ({
                        id: id,
                        from: from,
                        to: to,
                        kind: "message",
                        text: "From " + from,
                        at: new Date().toISOString()
                    });
            plugin.publish(people, [say("a", "b", "talk-1"), say("b", "a", "talk-2")]);
            const talked = {};
            runUntil(() => {
                verify(!(a.talk && b.talk), "one of them talks at a time");
                // Only a talk that gets to its line counts, not one that gives
                // up on the way.
                if (a.talk && a.talk.phase !== "go")
                    talked.a = true;
                if (b.talk && b.talk.phase !== "go")
                    talked.b = true;
                checkFloor();
                return talked.a && talked.b && !a.talk && !b.talk;
            }, 3000, "both talks run to their end");
            compare([a.hold, b.hold, a.heldBy, b.heldBy], [-1, -1, "", ""], "nobody holds a tile for a talk");
            const mine = Object.values(page.game.actors).map(p => p.claim);
            for (const tile of Object.keys(page.game.claims))
                verify(mine.includes(Number(tile)), "tile " + tile + " is claimed by " + page.game.claims[tile] + ", who stops elsewhere");
        }

        // A reviewer listening at a floor desk when a thread comes in to a full
        // floor keeps its desk: the office grows for the thread rather than
        // take the desk (see seatTeams()), and nobody ends up on a tile
        // someone else holds while the floor is laid out again. Were the desk
        // given away, its new owner would wait for the talk to end (see
        // seatGoal()).
        function test_a_reviewer_listening_at_a_floor_desk_keeps_it_when_the_floor_fills() {
            const reviewers = [];
            for (let i = 0; i < 9; i++)
                reviewers.push(reviewer("r" + i, "Review #" + i));
            const threads = many(40, "t", "working", "typing");
            plugin.publish(reviewers.concat(threads.slice(0, 39)));
            const r8 = actor("r8"), t0 = actor("t0");
            verify(page.world.seatOf["r8"].pod !== corner(), "r8 sits on the floor");
            runUntil(() => arrived(r8) && arrived(t0), 6000, "everyone sits down");
            const seat = page.world.seatOf["r8"];
            const tile = seat.y * page.world.cols + seat.x;
            plugin.publish(reviewers.concat(threads.slice(0, 39)), [
                {
                    id: "talk-1",
                    from: "t0",
                    to: "r8",
                    kind: "message",
                    text: "Got a minute?",
                    at: new Date().toISOString()
                }
            ]);
            runUntil(() => t0.talk?.phase === "say", 3000, "t0 talks to r8");
            compare(r8.hold, tile, "r8 listens at its desk");
            checkFloor();
            plugin.publish(reviewers.concat(threads));
            verify(page.world.pods.length > 6, "the office grows");
            compare(page.world.seatOf["r8"].index, seat.index, "r8 keeps its desk");
            const t39 = actor("t39");
            verify(page.world.seatOf["t39"].index !== seat.index, "t39 has a desk of its own");
            runUntil(() => {
                checkFloor();
                const at = (a, s) => arrived(a) && a.tx === s.x && a.ty === s.y;
                return !t0.talk && at(r8, page.world.seatOf["r8"]) && at(t39, page.world.seatOf["t39"]);
            }, 9000, "r8 and t39 each sit at their own desk");
        }

        // A floor desk given away while its reviewer listens there stays the
        // reviewer's until the talk ends: the new owner waits beside the pod
        // meanwhile (see seatGoal()), and sits down as soon as the reviewer
        // lets the tile go (see letGo()). No publish reaches the yieldTo()
        // fallback in seatTeams() that gives such a desk away: sync() grows
        // the office first, counting the whole review corner and every
        // reviewer on a floor desk, gridFor() never gives fewer pods than
        // asked, the office has no size cap, and pods being closed leave
        // room for the same count. So the test gives the desk away by hand.
        function test_a_listener_keeps_a_desk_given_away_until_the_talk_ends() {
            const reviewers = [];
            for (let i = 0; i < 9; i++)
                reviewers.push(reviewer("r" + i, "Review #" + i));
            plugin.publish(reviewers.concat(many(39, "t", "working", "typing")));
            const r8 = actor("r8"), t0 = actor("t0"), t1 = actor("t1");
            const w = page.world;
            verify(w.seatOf["r8"].pod !== corner(), "r8 sits on the floor");
            runUntil(() => arrived(r8) && arrived(t0) && arrived(t1), 6000, "everyone sits down");
            const seat = w.seatOf["r8"], other = w.seatOf["t1"];
            const tile = seat.y * w.cols + seat.x;
            plugin.publish(reviewers.concat(many(39, "t", "working", "typing")), [
                {
                    id: "talk-1",
                    from: "t0",
                    to: "r8",
                    kind: "message",
                    text: "Got a minute?",
                    at: new Date().toISOString()
                }
            ]);
            runUntil(() => t0.talk?.phase === "say", 3000, "t0 talks to r8");
            compare(r8.hold, tile, "r8 listens at its desk");
            checkFloor();
            // r8's desk goes to t1, and t1's to r8, as layout() and sync() do.
            w.seatOf["t1"] = seat;
            w.seatOf["r8"] = other;
            for (const a of [t1, r8]) {
                a.goal = null;
                a.decide(false);
            }
            compare(t1.goal.kind, "wait", "t1 waits for the desk r8 listens at");
            const pod = w.pods[seat.pod];
            verify(t1.goal.x < pod.x || t1.goal.x >= pod.x + pod.cols, "beside the pod");
            runUntil(() => {
                if (t0.talk) {
                    compare(page.game.claims[tile], "r8", "r8 keeps the tile while it listens");
                    compare([r8.tx, r8.ty], [seat.x, seat.y], "and stays on it");
                    compare(t1.goal.kind, "wait", "while t1 waits");
                }
                checkFloor();
                return !t0.talk;
            }, 3000, "the talk runs to its end");
            compare(t1.goal.kind, "desk", "t1 heads for its desk as soon as r8 lets it go");
            runUntil(() => {
                checkFloor();
                return arrived(t1) && t1.tx === seat.x && t1.ty === seat.y && arrived(r8) && r8.tx === other.x && r8.ty === other.y;
            }, 6000, "t1 and r8 each sit at their new desk");
        }

        // A speaker that finds every side of its listener taken keeps the spot
        // it had, rather than stop somewhere nobody holds for it.
        function test_a_speaker_with_no_side_free_keeps_its_spot() {
            plugin.publish(many(6, "t", "working", "typing"));
            const W = page.world.cols;
            const lead = actor("t0");
            const far = Object.values(page.game.actors).find(a => Math.abs(a.tx - lead.tx) + Math.abs(a.ty - lead.ty) > 2);
            verify(far, "someone sits away from the lead");
            const blocked = [];
            for (const [dx, dy] of [[-1, 0], [1, 0], [0, -1], [0, 1]]) {
                const i = (far.ty + dy) * W + far.tx + dx;
                if (page.game.walkable(far.tx + dx, far.ty + dy) && page.game.claims[i] === undefined) {
                    page.game.claims[i] = "someone";
                    blocked.push(i);
                }
            }
            plugin.publish(many(6, "t", "working", "typing"), [
                {
                    id: "talk-1",
                    from: "t0",
                    to: far.key,
                    kind: "message",
                    text: "Got a minute?",
                    at: new Date().toISOString()
                }
            ]);
            runUntil(() => !!lead.talk, 200, "the lead goes to talk");
            for (let i = 0; i < 200; i++) {
                page.game.advance(1);
                if (lead.next < 0 && lead.path.length === 0)
                    compare(page.game.claims[lead.ty * W + lead.tx], "t0", "the lead stands on a spot of its own");
            }
            compare(lead.talk.phase, "go", "the lead waits for a side to come free");
            for (const i of blocked)
                delete page.game.claims[i];
            runUntil(() => lead.talk?.phase === "say", 2000, "the talk starts once a side is free");
            compare(page.game.claims[lead.ty * W + lead.tx], "t0");
        }

        // The office fits the view as large as whole device pixels per art
        // pixel allow, and the zoom buttons step it a little at a time.
        function test_the_office_fits_the_view_and_zooms_in_small_steps() {
            plugin.publish(many(9, "t", "working", "typing"));
            tryVerify(() => page.game.columns > 0);
            verifyFitsWhole("the fit");
            const ratio = page.game.devicePixelRatio;
            const fitted = page.game.pixelScale;
            page.game.zoomBy(1.25);
            verify(page.game.pixelScale > fitted && page.game.pixelScale <= Math.max(fitted * 1.25 + 0.5 / ratio, fitted + 1 / ratio) + 1e-9, "one step zooms in by about a quarter, or one device pixel");
            page.game.zoom = 1;
            compare(page.game.pixelScale, fitted);
        }

        // A view wide enough to fit the office past the most zoomed in scale
        // shows it at that scale, drawn directly rather than through a layer
        // of the whole office at more device pixels than that.
        function test_a_huge_view_fits_at_most_the_top_scale() {
            loader.width = 16000;
            loader.height = 10000;
            plugin.publish(many(1, "t", "working", "typing"));
            tryVerify(() => page.game.columns > 0 && page.game.fitScale > page.game.maxScale, 1000, "the view fits the office past the most zoomed in scale");
            fuzzyCompare(page.game.pixelScale, page.game.topScale, 1e-9);
            verify(!find("officeArt").layer.enabled, "the art is drawn directly");
            verify(!find("officeZoomIn").enabled, "zooming in further is off");
        }

        // The whole office shows, each art pixel a whole number of device
        // pixels, and one more device pixel each would not fit.
        function verifyFitsWhole(what) {
            const game = page.game;
            const ratio = game.devicePixelRatio;
            const scroller = find("officeScroller");
            const stage = find("officeStage");
            const device = game.pixelScale * ratio;
            fuzzyCompare(device, Math.round(device), 1e-9, what + ": each art pixel is whole device pixels");
            verify(stage.width <= scroller.width + 0.5 && stage.height <= scroller.height + 0.5, what + ": the whole office shows");
            const bigger = (device + 1) / ratio;
            verify(game.pixelWidth * bigger > scroller.width - game.margin || game.pixelHeight * bigger > scroller.height - game.margin || bigger > game.topScale + 1e-9, what + ": as large as fits");
            verify(!find("officeArt").layer.enabled, what + ": the art is drawn directly");
        }

        // A large view fits the office as large as whole device pixels allow.
        function test_a_large_fit_is_as_large_as_whole_pixels_allow() {
            loader.width = 2600;
            loader.height = 1600;
            plugin.publish(many(1, "t", "working", "typing"));
            tryVerify(() => page.game.columns > 0 && page.game.fitScale * page.game.devicePixelRatio >= 4, 1000, "the office fits at 4 device pixels or more");
            verifyFitsWhole("a large fit");
            loader.width = 2611;
            loader.height = 1633;
            verifyFitsWhole("a view a little larger");
        }

        // Where zoom snaps to whole device pixels, zooming in and back out
        // returns to the same scale.
        function test_zooming_in_and_out_returns_to_the_same_scale() {
            plugin.publish(many(1, "t", "working", "typing"));
            tryVerify(() => page.game.columns > 0);
            page.game.zoom = 4 / page.game.devicePixelRatio / page.game.fitScale;
            for (let i = 0; i < 12 && page.game.pixelScale < page.game.topScale - 0.001; i++) {
                const before = page.game.pixelScale;
                page.game.zoomBy(1.25);
                // A step held back by the most zoomed in scale is not undone.
                if (page.game.pixelScale >= page.game.topScale - 0.001)
                    break;
                const after = page.game.pixelScale;
                page.game.zoomBy(1 / 1.25);
                fuzzyCompare(page.game.pixelScale, before, 1e-9, "out undoes in");
                page.game.zoomBy(1.25);
                fuzzyCompare(page.game.pixelScale, after, 1e-9, "in again goes as far");
            }
        }

        // The most zoomed in scale is a whole number of device pixels within
        // the most zoom allows, and the zoom-in button stops there.
        function test_the_most_zoomed_in_scale_is_whole_device_pixels() {
            plugin.publish(many(1, "t", "working", "typing"));
            tryVerify(() => page.game.columns > 0);
            const ratio = page.game.devicePixelRatio;
            fuzzyCompare(page.game.topScale * ratio, Math.round(page.game.topScale * ratio), 1e-9);
            verify(page.game.topScale <= page.game.maxScale + 1e-9 && page.game.topScale > page.game.maxScale - 1 / ratio, "as far in as whole device pixels go");
            page.game.zoom = page.game.maxScale / page.game.fitScale;
            fuzzyCompare(page.game.pixelScale, page.game.topScale, 1e-9);
            verify(!find("officeZoomIn").enabled, "zooming in further is off");
        }

        // A zoom set between whole device pixels shows the whole one below it;
        // the step from there goes to the next whole one, not one past it.
        function test_a_step_from_between_whole_pixels_goes_to_the_next() {
            plugin.publish(many(1, "t", "working", "typing"));
            tryVerify(() => page.game.columns > 0);
            const ratio = page.game.devicePixelRatio;
            page.game.zoom = 3.55 / ratio / page.game.fitScale;
            page.game.zoomBy(1.25);
            fuzzyCompare(page.game.pixelScale * ratio, 4, 1e-9, "3.55 device pixels steps in to 4");
        }

        // A zoom between whole device pixels shows the whole one below it, so
        // each art pixel stays a hard block; only an office shown smaller than
        // one device pixel per art pixel is drawn at one and shrunk smoothly.
        function test_art_pixels_are_hard_blocks_at_any_zoom() {
            plugin.publish(many(3, "t", "working", "typing"));
            tryVerify(() => page.game.columns > 0);
            const art = find("officeArt");
            const stage = find("officeStage");
            const ratio = page.game.devicePixelRatio;
            page.game.zoom = 3.5 / ratio / page.game.fitScale;
            fuzzyCompare(page.game.pixelScale * ratio, 3, 1e-9, "3.5 device pixels shows 3");
            verify(!art.layer.enabled, "the art is drawn directly");
            compare(art.scale, 1);
            loader.width = 120;
            loader.height = 90;
            page.game.zoom = 1;
            tryVerify(() => page.game.pixelScale * ratio < 1, 1000, "the office is shown under a device pixel per art pixel");
            verify(art.layer.enabled && art.layer.smooth, "the art is shrunk smoothly");
            fuzzyCompare(art.width * art.scale, stage.width, 1e-6);
        }

        // Zoomed far in, a step of one device pixel is fine enough, so the
        // scale snaps to whole device pixels and no layer the size of the
        // whole zoomed office is drawn.
        function test_zoomed_in_far_the_art_is_drawn_directly() {
            plugin.publish(many(20, "t", "working", "typing"));
            tryVerify(() => page.game.columns > 0);
            const art = find("officeArt");
            let steps = 0;
            while (page.game.pixelScale < page.game.topScale - 0.001 && steps < 40) {
                const before = page.game.pixelScale;
                page.game.zoomBy(1.25);
                verify(page.game.pixelScale > before, "each step zooms in");
                if (art.layer.enabled)
                    verify(page.game.drawScale * page.game.devicePixelRatio <= 4, "a layer is drawn only at a small scale");
                steps++;
            }
            fuzzyCompare(page.game.pixelScale, page.game.topScale, 1e-9);
            verify(!art.layer.enabled, "the most zoomed in office is drawn directly");
            while (page.game.pixelScale > 1.001 && steps < 80) {
                const before = page.game.pixelScale;
                page.game.zoomBy(1 / 1.25);
                verify(page.game.pixelScale < before, "each step zooms out");
                steps++;
            }
        }

        // A view smaller than the office still fits all of it, and a zoom step
        // after the view changes moves the scale from what is shown.
        function test_a_small_view_fits_the_office_and_zoom_steps_from_what_shows() {
            plugin.publish(many(3, "t", "working", "typing"));
            tryVerify(() => page.game.columns > 0);
            const scroller = find("officeScroller");
            const stage = find("officeStage");
            while (page.game.pixelScale > page.game.minScale + 0.001)
                page.game.zoomBy(1 / 1.25);
            loader.height = 200;
            tryVerify(() => page.game.fitScale < 1, 1000, "the office is taller than the view");
            verify(stage.width <= scroller.width + 0.5 && stage.height <= scroller.height + 0.5, "the whole office shows when zoomed out");
            const shown = page.game.pixelScale;
            page.game.zoomBy(1.25);
            verify(page.game.pixelScale > shown, "the first step after the view shrank zooms in");
            page.game.zoom = 1;
            verify(stage.width <= scroller.width + 0.5 && stage.height <= scroller.height + 0.5, "the whole office shows at Fit");
        }

        function test_a_person_tabbed_to_is_scrolled_into_view() {
            plugin.publish(many(20, "t", "working", "typing"));
            tryVerify(() => page.settled);
            page.game.zoom = page.game.maxScale / page.game.fitScale;
            const scroller = find("officeScroller");
            const far = Object.values(page.game.actors).reduce((m, a) => a.tx + a.ty > m.tx + m.ty ? a : m);
            const hit = find("officePerson:" + far.key);
            const inView = () => {
                const r = hit.mapToItem(scroller, 0, 0, hit.width, hit.height);
                // Half a pixel either way is rounding, not out of view.
                return r.x >= -0.5 && r.y >= -0.5 && r.x + r.width <= scroller.width + 0.5 && r.y + r.height <= scroller.height + 0.5;
            };
            verify(!inView(), "the person starts out of view");
            hit.forceActiveFocus();
            verify(inView(), "the person is scrolled into view");
            compare(page.hovered, far.key);
            // Its card is beside it, in view too, though the stage goes on.
            const card = find("officeCard");
            tryVerify(() => card.visible);
            const c = card.mapToItem(scroller, 0, 0, card.width, card.height);
            verify(c.x >= -0.5 && c.y >= -0.5 && c.x + c.width <= scroller.width + 0.5 && c.y + c.height <= scroller.height + 0.5, JSON.stringify(c));
        }

        // Zoomed in, the page's message is in the middle of the view, not of
        // the office it is over.
        function test_the_message_is_in_the_middle_of_the_view_at_any_zoom() {
            plugin.environments = ["local", "lab"];
            plugin.publish(many(20, "t", "working", "typing"));
            tryVerify(() => page.settled);
            page.game.zoom = page.game.maxScale / page.game.fitScale;
            page.environment = "lab";
            compare(message(), "Waiting for the office…");
            const scroller = find("officeScroller");
            const text = find("officeMessage");
            const r = text.mapToItem(scroller, 0, 0, text.width, text.height);
            fuzzyCompare(r.x + r.width / 2, scroller.width / 2, 1);
            fuzzyCompare(r.y + r.height / 2, scroller.height / 2, 1);
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

        function test_another_machine_chosen_while_people_are_still_painted_settles() {
            plugin.environments = ["local", "lab"];
            plugin.publish(many(40, "t", "working", "typing"));
            page.environment = "lab";
            plugin.watchers["lab/office"]({
                people: [],
                talks: []
            });
            tryVerify(() => page.settled, 10000, "the other machine's empty office shows");
            compare(Object.keys(page.game.actors).length, 0, "with nobody from the first");
        }

        function test_an_asking_person_shows_a_question_and_opens_its_thread() {
            plugin.publish([person("ask", "Fix the parser", "asking"), person("busy", "Busy", "working", "typing")]);
            runUntil(() => arrived(actor("ask")));
            compare(actor("ask").headIcon, "ask");
            verify(find("officeIcon:ask").visible);
            verify(!find("officeIcon:busy").visible);
            tryVerify(() => page.settled);
            waitForRendering(loader.item);
            mouseClick(find("officePerson:ask"));
            compare(plugin.opened, ["local/ask"]);
        }

        function test_hovering_a_person_names_it_and_what_it_does() {
            plugin.publish([person("t", "Fix the parser", "working", "testing")]);
            runUntil(() => arrived(actor("t")));
            tryVerify(() => page.settled);
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
            tryVerify(() => page.settled);
            const hit = find("officePerson:ask");
            hit.forceActiveFocus();
            compare(page.hovered, "ask");
            keyClick(Qt.Key_Return);
            compare(plugin.opened, ["local/ask"]);
        }

        function test_the_first_people_sit_at_desks_already_there() {
            plugin.publish(many(4, "t", "working", "typing"));
            compare(page.deskCount, 4);
            compare(page.moves, 0, "nobody carries a desk");
            for (let i = 0; i < 4; i++) {
                const seat = page.world.seatOf["t" + i];
                compare([actor("t" + i).tx, actor("t" + i).ty], [seat.x, seat.y], "t" + i + " is at its desk");
            }
        }

        // A worker who comes in walks in through the door and waits, and a
        // mover carries its desk in before it sits down.
        function test_a_desk_is_carried_in_before_its_worker_sits() {
            plugin.publish(many(4, "t", "working", "typing"));
            plugin.publish(many(5, "t", "working", "typing"));
            const seat = page.world.seatOf["t4"];
            compare(seat.state, "coming");
            page.game.advance(1);
            compare([actor("t4").tx, actor("t4").ty], page.world.entrance, "t4 walks in through the door");
            compare(page.deskCount, 4);
            let carried = false;
            runUntil(() => {
                carried = carried || Object.values(page.crew.members).some(m => m.carrying);
                if (seat.state !== "in")
                    verify(actor("t4").tx !== seat.x || actor("t4").ty !== seat.y, "t4 does not sit before its desk is there");
                return seat.state === "in";
            }, 1500, "the desk is set down");
            verify(carried, "a mover carried it");
            compare(page.deskCount, 5);
            runUntil(() => arrived(actor("t4")), 1500, "t4 reaches its desk");
            compare([actor("t4").tx, actor("t4").ty], [seat.x, seat.y]);
            runUntil(() => page.moves === 0, 1500, "the mover leaves");
            compare(Object.keys(page.crew.members).length, 0);
        }

        // A waiting person whose desk is still being carried in waits for it,
        // and its breaks count from when it sits down.
        function test_a_break_waits_until_the_person_has_sat_down() {
            const busy = many(40, "w", "working", "typing");
            plugin.publish(busy);
            const people = many(30, "t", "waiting");
            plugin.publish(busy.concat(people));
            for (const p of people)
                actor(p.id).restless = 1;
            const sat = {};
            const armed = {};
            let late = 0;
            runUntil(() => {
                for (const p of people) {
                    const a = actor(p.id), seat = page.world.seatOf[p.id];
                    if (a.tx === seat.x && a.ty === seat.y) {
                        sat[p.id] = sat[p.id] ?? page.game.now;
                        // The first rest after it sits, before a break
                        // replaces it, is 15 to 45 seconds from then; the
                        // tick after it sits sets it.
                        if (armed[p.id] === undefined && a.plan === "rest" && a.until !== Infinity) {
                            armed[p.id] = a.until;
                            verify(a.until >= sat[p.id] + 15000 && a.until <= sat[p.id] + 45040, p.id + " rests 15 to 45 seconds from when it sat down, not until " + (a.until - sat[p.id]) + " ms after");
                        }
                    } else if (sat[p.id] === undefined) {
                        verify(a.plan !== "break", p.id + " goes on a break before it ever sat down");
                        if (seat.state !== "in" && page.game.now > 15000)
                            late++;
                    }
                }
                return people.every(p => armed[p.id] !== undefined);
            }, 3000, "everyone sits down and rests");
            verify(late > 0, "some desks arrive after a rest would have ended");
        }

        // When a team leaves, movers carry its desks out and leave.
        function test_a_desk_is_carried_out_after_its_pod_empties() {
            const a = [person("a", "A", "working", "typing")].concat(many(5, "aw", "working", "typing", "a"));
            const b = [person("b", "B", "working", "typing")].concat(many(5, "bw", "working", "typing", "b"));
            plugin.publish(a.concat(b));
            compare(page.deskCount, 12);
            const pod = page.world.pods.find(p => p.members.includes("b"));
            const used = b.map(p => page.world.seatOf[p.id]);
            plugin.publish(a);
            compare(pod.members.length, 0);
            for (const seat of used)
                compare(seat.state, "leaving");
            runUntil(() => used.every(seat => seat.state === "out"), 3000, "the desks are picked up");
            compare(page.deskCount, 6);
            runUntil(() => page.moves === 0, 1500, "the movers leave");
        }

        // Several movers carry desks at once, and people walk past them, as
        // past anyone, never stopping where another stops.
        function test_movers_carry_desks_at_once_among_the_people() {
            plugin.publish(many(4, "t", "working", "typing"));
            checkFloor();
            const activities = ["typing", "planning", "reading", "testing"];
            const people = [];
            for (let i = 0; i < 16; i++)
                people.push(person("t" + i, "Thread " + i, "working", activities[i % 4]));
            plugin.publish(people);
            let carrying = 0;
            for (let i = 0; i < 3000 && page.moves > 0; i++) {
                page.game.advance(1);
                checkFloor();
                carrying = Math.max(carrying, Object.values(page.crew.members).filter(m => m.carrying).length);
            }
            compare(page.moves, 0, "the desks are all in");
            verify(carrying > 1, "movers carried desks at once");
            compare(page.deskCount, 16);
        }

        // A mover carrying a desk right past someone standing just north of its
        // way never covers them with the desk.
        function test_a_carried_desk_never_covers_the_person_north_of_it() {
            plugin.publish(many(4, "t", "working", "typing"));
            plugin.publish(many(5, "t", "working", "typing"));
            runUntil(() => Object.keys(page.crew.members).length > 0, 400, "a mover comes in");
            const w = page.world;
            const m = Object.values(page.crew.members)[0];
            const key = m.key;
            verify(m.carrying, "it carries a desk");
            // It carries the desk along open floor instead of to its seat, past
            // t0 standing just north of the way.
            w.seats[m.job].mover = "";
            m.job = -1;
            m.path = [];
            const t0 = actor("t0");
            const [left, row] = openFloor(5);
            standAt(t0, left + 2, row - 1);
            m.place(left, row, true);
            m.goal = {
                x: left + 4,
                y: row,
                face: 0,
                offY: 0,
                pose: "stand",
                kind: "leave"
            };
            m.route();
            stood = {};
            let under = false;
            for (let i = 0; i < 600 && page.crew.members[key]; i++) {
                walk(1);
                if (!page.crew.members[key])
                    break;
                under = under || m.tx === left + 2 && m.ty === row;
                verify(!crosses(load(m), body(t0)), "the desk covers t0");
            }
            verify(under, "the mover passes just south of t0");
            verify(!page.crew.members[key], "the mover gets where it is going");
            compare([t0.tx, t0.ty], [left + 2, row - 1], "t0 stays where it stands");
        }

        // A newcomer waiting for its desk while every pod side is taken waits
        // on a tile nobody else is headed for.
        function test_newcomers_waiting_for_desks_never_share_a_tile() {
            plugin.publish([]);
            plugin.publish(many(16, "t", "working", "typing"));
            const check = () => {
                const at = {};
                for (const id of Object.keys(page.game.actors)) {
                    const goal = actor(id).goal;
                    if (goal?.kind !== "wait")
                        continue;
                    const key = goal.x + "," + goal.y;
                    verify(at[key] === undefined, id + " and " + at[key] + " both wait at " + key);
                    at[key] = id;
                    compare(page.game.claims[goal.y * page.world.cols + goal.x], id, id + " holds its claim");
                }
            };
            check();
            for (let i = 0; i < 400; i++) {
                page.game.advance(1);
                check();
            }
        }

        // A talk to someone still outside the door waits for it to come in, while
        // the office still has it:
        // the speaker's time to find its listener starts only then.
        function test_a_talk_waits_for_its_listener_to_come_in() {
            plugin.publish(many(4, "t", "working", "typing"));
            // The doorway lets nobody through for longer than a speaker looks
            // for its listener.
            page.doorOpensAt = 1e12;
            plugin.publish(many(5, "t", "working", "typing"), [
                {
                    id: "talk-1",
                    from: "t0",
                    to: "t4",
                    kind: "message",
                    text: "Welcome",
                    at: new Date().toISOString()
                }
            ]);
            for (let i = 0; i < 800; i++) {
                page.game.advance(1);
                compare(actor("t4").tx, -1, "t4 waits outside");
                compare(actor("t0").talk, null, "t0 waits for t4 to come in");
            }
            page.doorOpensAt = 0;
            runUntil(() => actor("t0").talk?.phase === "say", 2000, "t0 talks to t4 once it is in");
            compare(actor("t0").talk.to, "t4");
        }

        // A talk waiting for its listener to come in does not hold up the
        // speaker's talks to people already inside.
        function test_a_talk_to_someone_outside_lets_the_next_talk_go_first() {
            plugin.publish(many(4, "t", "working", "typing"));
            page.doorOpensAt = 1e12;
            const at = new Date().toISOString();
            plugin.publish(many(5, "t", "working", "typing"), [
                {
                    id: "talk-1",
                    from: "t0",
                    to: "t4",
                    kind: "message",
                    text: "Welcome",
                    at: at
                },
                {
                    id: "talk-2",
                    from: "t0",
                    to: "t1",
                    kind: "message",
                    text: "Please look at the diff",
                    at: at
                }
            ]);
            runUntil(() => actor("t0").talk?.phase === "say", 2000, "t0 talks to t1 while t4 waits outside");
            compare(actor("t0").talk.to, "t1");
            compare(actor("t4").tx, -1, "t4 is still outside");
            compare(actor("t0").queue.map(t => t.to), ["t4"], "the talk to t4 waits its turn");
            page.doorOpensAt = 0;
        }

        // Talks to people outside do not fill a speaker's queue so that a talk
        // to someone inside is lost.
        function test_talks_to_people_outside_never_crowd_out_one_inside() {
            plugin.publish(many(4, "t", "working", "typing"));
            page.doorOpensAt = 1e12;
            const at = new Date().toISOString();
            const talk = (id, to) => ({
                    id: id,
                    from: "t0",
                    to: to,
                    kind: "message",
                    text: id,
                    at: at
                });
            plugin.publish(many(8, "t", "working", "typing"), [talk("o1", "t4"), talk("o2", "t5"), talk("o3", "t6"), talk("in", "t1")]);
            runUntil(() => actor("t0").talk?.phase === "say", 2000, "t0 talks to t1 while the others wait outside");
            compare(actor("t0").talk.to, "t1");
            page.doorOpensAt = 0;
        }

        // A whiteboard fills by the time spent drawing on it, the same on
        // the walking clock's 40 ms ticks as on the quiet clock's 200 ms
        // ones: 12 s from blank to full.
        function test_a_whiteboard_fills_by_time_on_either_clock() {
            plugin.publish([person("lead", "Lead", "working", "planning")]);
            runUntil(() => arrived(actor("lead")));
            const board = viewsIn(page.boardViews)[actor("lead").goal.board];
            runUntil(() => board.progress > 0.05, 2000, "the planner draws");
            // From just after the screens changed, so both runs count the
            // same 2.4 s.
            const settle = () => {
                for (let i = 0; i < 10 && page.screensAt !== page.game.now + 200; i++)
                    page.game.tick(40);
                compare(page.screensAt, page.game.now + 200, "the screens just changed");
            };
            settle();
            const start = board.progress;
            for (let i = 0; i < 60; i++)
                page.game.tick(40);
            const walking = board.progress - start;
            settle();
            board.progress = start;
            for (let i = 0; i < 12; i++)
                page.game.tick(200);
            const quiet = board.progress - start;
            verify(arrived(actor("lead")), "the planner stays at the board");
            fuzzyCompare(walking, 0.2, 0.02, "2.4 s on the walking clock fills a fifth");
            fuzzyCompare(quiet, walking, 0.02, "and as much on the quiet clock");
        }

        // A quiet office touches no screen: idle and waiting screens only
        // change when their picture does, never just because time passes.
        function test_quiet_screens_do_not_change_with_the_clock() {
            plugin.publish(many(16, "t", "idle"));
            runUntil(() => Object.values(page.game.actors).every(arrived), 6000, "everyone sits down");
            page.game.advance(10);
            const views = Object.values(viewsIn(page.screenViews)).filter(v => v.mode === "idle" && !v.slacking);
            verify(views.length > 0, "some screens show the idle screen");
            const phases = views.map(v => v.phase);
            for (let i = 0; i < 10; i++)
                page.game.tick(200);
            compare(views.map(v => v.phase), phases, "their phase stays put");
        }

        // Another machine's office starts with clean whiteboards.
        function test_another_machine_wipes_the_whiteboards() {
            plugin.publish([person("lead", "Lead", "working", "planning")]);
            runUntil(() => arrived(actor("lead")));
            const key = actor("lead").goal.board;
            const board = viewsIn(page.boardViews)[key];
            const blank = board.progress;
            runUntil(() => board.progress > blank, 200, "the planner draws");
            plugin.environments = ["local", "lab"];
            page.environment = "lab";
            verify(viewsIn(page.boardViews)[key] === board, "the same whiteboard");
            compare(board.progress, blank, "wiped");
        }

        // People walking in while movers carry several desks in and out all get
        // through the door, and nobody stands waiting in the doorway.
        function test_people_and_movers_get_through_the_door() {
            const activities = ["typing", "planning", "reading", "testing"];
            const office = n => many(n, "t", "working", "typing").map((p, i) => Object.assign(p, {
                        activity: activities[i % 4]
                    }));
            for (const [before, after] of [[2, 8], [12, 16], [10, 2], [2, 14]]) {
                open();
                stood = {};
                const w = page.world;
                const e = w.entrance;
                plugin.publish(office(before));
                page.game.advance(40);
                plugin.publish(office(after));
                let inDoor = "", since = 0, ticks = 0;
                while ((page.moves || page.outside.length) && ticks < 2000) {
                    page.game.advance(1);
                    ticks++;
                    const there = Object.values(page.game.actors).concat(Object.values(page.crew.members)).find(a => a.tx === e[0] && a.ty === e[1] && a.next < 0)?.key ?? "";
                    since = there && there === inDoor ? since + 1 : 0;
                    inDoor = there;
                    verify(since < 40, there + " stands in the doorway");
                    checkFloor();
                }
                verify(ticks < 2000, before + " to " + after + ": everyone gets through, " + page.moves + " moves are left");
                page.game.advance(300);
                for (const id of Object.keys(page.game.actors)) {
                    const a = page.game.actors[id];
                    verify(a.tx >= 0 && a.goal && a.tx === a.goal.x && a.ty === a.goal.y, id + " gets where it is going");
                }
            }
        }

        // People coming in do not repaint the floor or the furniture.
        function test_people_coming_in_do_not_repaint_the_floor() {
            plugin.publish(many(4, "t", "working", "typing"));
            tryVerify(() => page.floorPaints > 0);
            const paints = page.floorPaints;
            const world = page.world, seats = world.seats;
            plugin.publish(many(12, "t", "working", "typing"));
            page.game.advance(200);
            plugin.publish(many(2, "t", "working", "typing"));
            page.game.advance(200);
            wait(50);
            compare(page.floorPaints, paints);
            verify(page.world === world && page.world.seats === seats, "the furniture is the same");
        }

        function message() {
            return find("officeMessage").visible ? find("officeMessage").text : "";
        }

        // A full office opens on a page that says it is being set up, with its
        // header laid out; the sprite sheets are painted a few a frame, and the
        // office shows once everyone is drawn.
        function test_a_full_office_says_it_is_being_set_up_until_it_is_drawn() {
            plugin.publish(many(40, "t", "idle"));
            compare(message(), "Setting up the office…");
            compare(find("officeStage").opacity, 0, "nothing half drawn shows");
            verify(!find("officePerson:t0").visible, "nobody can be hovered or clicked yet");
            page.game.forceActiveFocus();
            for (let i = 0; i < 3; i++)
                keyClick(Qt.Key_Tab);
            verify(!String(page.Window.activeFocusItem?.objectName ?? "").startsWith("officePerson"), "nor reached with Tab");
            compare(page.game.sheetsPending, 40);
            // The sheets are painted a few a frame, not all at once.
            tryVerify(() => page.game.sheetsPending < 40);
            verify(page.game.sheetsPending > 0, "all sheets were painted in one batch, not a few a frame");
            waitForRendering(page);
            const summary = find("officeSummary");
            verify(find("officeZoomIn").x >= summary.x + summary.width, "the zoom buttons sit beside the summary");
            tryVerify(() => page.settled, 5000);
            compare(page.game.sheetsPending, 0);
            compare(message(), "");
            compare(find("officeStage").opacity, 1);
            verify(find("officePerson:t0").visible);
            verify(page.game.sheetCost > 0, "what a sheet takes is known");
            // The first people are already where they belong.
            for (const id of Object.keys(page.game.actors))
                verify(!page.outside.includes(id), id + " is not waiting outside");
        }

        // Before a machine's office arrives the page waits for it, which is not
        // the same as setting it up; an empty office says nobody is in.
        function test_waiting_for_the_office_and_an_empty_office_are_not_setting_up() {
            compare(message(), "Waiting for the office…");
            verify(!page.settled);
            plugin.publish([]);
            compare(message(), "Nobody is in the office. Threads show up here as they work.");
            tryVerify(() => page.settled);
            plugin.publish(many(3, "t", "working", "typing"));
            compare(message(), "", "newcomers to a settled office just walk in");
            tryVerify(() => page.game.sheetsPending === 0);
            compare(message(), "");
        }

        // Another machine's office is set up afresh; one whose office has not
        // arrived waits for it.
        function test_another_machine_is_set_up_afresh() {
            plugin.publish(many(4, "t", "working", "typing"));
            tryVerify(() => page.settled);
            plugin.environments = ["local", "lab"];
            page.environment = "lab";
            compare(message(), "Waiting for the office…");
            plugin.watchers["lab/office"]({
                people: many(6, "x", "idle"),
                talks: []
            });
            compare(message(), "Setting up the office…");
            tryVerify(() => page.settled);
            compare(message(), "");
            page.environment = "local";
            compare(message(), "Setting up the office…");
            // Its people are where they belong, not walking in from the door.
            compare(Object.keys(page.game.actors).sort(), ["t0", "t1", "t2", "t3"]);
            for (const id of Object.keys(page.game.actors))
                verify(page.game.actors[id].tx >= 0 && !page.outside.includes(id), id + " is already in");
            tryVerify(() => page.settled);
        }

        // A page hidden while it is set up waits to be shown again; once
        // shown, hiding it, zooming and Fit leave the office as drawn.
        function test_setting_up_waits_while_the_page_is_not_shown() {
            plugin.publish(many(8, "t", "idle"));
            page.visible = false;
            verify(!find("officeSheetPainter").running, "no sheet is asked for while hidden");
            compare(page.game.sheetsPending, 8);
            page.visible = true;
            tryVerify(() => page.settled);
            page.visible = false;
            page.visible = true;
            find("officeZoomIn").clicked();
            page.game.zoom = 1;
            compare(page.game.sheetsPending, 0);
            compare(message(), "");
            verify(page.settled);
        }

        function test_the_office_holds_still_while_it_is_not_shown() {
            plugin.publish(many(2, "t", "working", "typing"));
            page.inSight = true;
            verify(page.game.running);
            page.visible = false;
            verify(!page.game.running);
            page.visible = true;
            verify(page.game.running);
            page.inSight = false;
            verify(!page.game.running);
        }

        function test_a_minimized_office_holds_still_until_it_is_back() {
            // The page's own sense of sight, not the clock open() holds still.
            // Focus is not part of it (a window without focus still shows the
            // office), but a test cannot take focus away from its own window.
            loader.source = "";
            loader.setSource(Qt.resolvedUrl("../ui/OfficePage.qml"), {
                plugin: plugin
            });
            tryVerify(() => loader.status === Loader.Ready && plugin.watchers["local/office"] !== undefined);
            plugin.publish(many(2, "t", "working", "typing"));
            verify(page.game.running);
            const window = test.Window.window;
            window.showMinimized();
            tryVerify(() => !page.game.running, 5000, "a minimized office holds still");
            window.showNormal();
            tryVerify(() => page.game.running, 5000, "and goes on once it is back");
        }
    }
}
