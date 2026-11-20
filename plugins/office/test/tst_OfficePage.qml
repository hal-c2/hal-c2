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

        function cleanup() {
            loader.source = "";
            Shell.state = Object.assign({}, Shell.state, {
                projectIcons: undefined
            });
        }

        function actor(id) {
            return page.actors[id];
        }

        function corner() {
            return page.world.pods.findIndex(pod => pod.review);
        }

        function markOf(id) {
            return page.markViews["mark:" + page.world.seatOf[id].index];
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
                page.advance(1);
            }
            verify(done(), message ?? "the office never got there");
        }

        function arrived(a) {
            return a.goal && a.tx === a.goal.x && a.ty === a.goal.y && a.next < 0 && a.path.length === 0;
        }

        // The tiles each person held when the floor was last checked.
        property var stood: ({})

        // Nobody, people or movers, stands on a wall or furniture or off the
        // floor, a seat is only stepped onto as where a person is going (a
        // step already begun ends there, and the person leaves again), and a
        // step goes to a tile next to the person. People walk through each
        // other, but each claims the tile it stops at, and no two stop on one
        // tile. A carried desk is drawn within its mover's figure.
        function checkFloor() {
            const w = page.world;
            const stopped = {};
            const stood = {};
            const everyone = Object.assign({}, page.actors, page.movers);
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
                    const cell = w.grid[t];
                    const goal = a.goal && a.goal.x === x && a.goal.y === y;
                    const stayed = (this.stood[id] ?? []).includes(t);
                    verify(cell === 0 || cell === 2 && (goal || stayed), id + " stands on furniture at " + x + "," + y);
                }
                if (a.next < 0 && a.path.length === 0) {
                    verify(stopped[here] === undefined, id + " and " + stopped[here] + " stop on one tile at " + a.tx + "," + a.ty);
                    stopped[here] = id;
                }
                if (page.actors[id] && a.goal)
                    compare(page.claims[a.goal.y * w.cols + a.goal.x], id, id + " claims the tile it stops at, " + a.goal.x + "," + a.goal.y);
                stood[id] = tiles;
            }
            this.stood = stood;
            for (const m of Object.values(page.movers)) {
                if (!m.carrying)
                    continue;
                const r = load(m);
                verify(r[0] >= m.px && r[1] >= m.py - 8 && r[0] + r[2] <= m.px + 16 && r[1] + r[3] <= m.py + 16, m.id + "'s desk is drawn within its figure");
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
            page.claim(who, goal);
            page.setGoal(who, goal);
        }

        // Takes a person off wherever it is and stands it at a tile.
        function standAt(who, x, y) {
            who.goal = null;
            who.path = [];
            page.release(who);
            page.place(who, x, y, true);
            send(who, x, y);
        }

        // Where a person is drawn, from the top of its head to its shoes (its
        // shadow below them is see-through), and where a carried desk is.
        function body(a) {
            return [a.px, a.py - 8 + a.offY, 16, 21];
        }

        function load(m) {
            const v = find("officeLoad:" + m.id);
            verify(v, m.id + "'s desk is drawn");
            return [m.px + v.x, m.py - 8 + v.y, v.width, v.height];
        }

        function crosses(r, q) {
            return r[0] < q[0] + q[2] && q[0] < r[0] + r[2] && r[1] < q[1] + q[3] && q[1] < r[1] + r[3];
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

        // The corner's desks are reviewers' alone: with the rest of the floor
        // full, anyone else goes without a desk rather than sit there.
        function test_a_full_floor_never_seats_others_in_the_review_corner() {
            plugin.publish(many(46, "t", "working", "typing").concat([reviewer("r", "Review #12")]));
            const review = corner();
            const seated = Object.keys(page.world.seatOf).filter(id => id !== "r");
            compare(seated.length, 40, "the floor's 40 desks are taken");
            for (const id of seated)
                verify(page.world.seatOf[id].pod !== review, id + " sits on the floor");
            compare(page.world.seatOf["r"].pod, review, "the reviewer has a corner desk");
            for (let i = 40; i < 46; i++)
                verify(!page.world.seatOf["t" + i], "t" + i + " has no desk");
            compare(page.world.pods[review].members, ["r"], "nobody else sits in the corner");
        }

        // Someone in the corner who is no reviewer leaves it at the next
        // seating, for a desk on the floor or none when the floor is full.
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
            verify(!page.world.seatOf["a"], "with the floor full, a has no desk");
            compare(page.world.pods[review].members, [], "the corner is empty");
        }

        // Reviewers past the corner's desks take a floor desk only when no
        // other thread needs it, wherever they come in the list.
        function test_reviewers_past_the_corner_take_no_desk_others_need() {
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
            compare(reviewers.filter(r => !page.world.seatOf[r.id]).length, 2, "the other 2 reviewers have no desk");
        }

        // Someone reading at a shelf who loses its corner desk on a full floor
        // waits in the break room, rather than read on without a desk.
        function test_a_reader_who_leaves_the_corner_on_a_full_floor_waits_in_the_break_room() {
            const reading = p => Object.assign(p, {
                    activity: "reading"
                });
            plugin.publish(many(40, "t", "working", "typing").concat([reading(reviewer("a", "Review #12"))]));
            compare(actor("a").goal.kind, "shelf", "a reads at a shelf");
            plugin.publish(many(40, "t", "working", "typing").concat([reading(person("a", "Review #12", "working"))]));
            verify(!page.world.seatOf["a"], "a has no desk");
            verify(actor("a").goal.x > page.world.xd, "a waits in the break room, not at a " + actor("a").goal.kind);
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
            page.advance(200);
            plugin.publish(many(6, "t", "working", "typing").concat([web]));
            page.advance(200);
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
            const aside = page.world.seatOf["aw6"];
            const z = [person("z", "Z", "working", "typing")].concat(many(31, "zw", "working", "typing", "z"));
            plugin.publish([person("x", "X", "working", "typing")].concat(team(7), z));
            verify(page.world.seatOf["aw6"] === aside, "aw6 keeps its seat");
            compare(Object.keys(page.world.seatOf).filter(id => page.world.seatOf[id] === aside), ["aw6"]);
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

        // A worker without a desk that asks or fails keeps the break room spot
        // it heads for, so nobody else is sent there.
        function test_a_worker_without_a_desk_keeps_its_spot_while_it_asks() {
            for (const state of ["asking", "failed"]) {
                init();
                plugin.publish(many(40, "t", "working", "typing").concat([person("q", "Q", state)]));
                const q = actor("q");
                verify(page.world.seatOf["q"] === undefined, "q has no desk");
                for (let i = 0; i < 20; i++) {
                    page.decide(q, false);
                    compare(q.claim, q.goal.y * page.world.cols + q.goal.x, state + ": q holds the spot it heads for");
                    compare(page.claims[q.claim], "q", state + ": the spot is q's");
                }
            }
        }

        // The office holds 48 desks whoever is in it, 8 of them the review
        // corner's; anyone past that takes a break.
        function test_the_office_keeps_its_size_as_people_come_and_go() {
            plugin.publish(many(4, "t", "working", "typing"));
            const cols = page.worldCols, rows = page.worldRows;
            const world = page.world;
            const reviewers = [0, 1, 2, 3, 4, 5, 6, 7].map(i => reviewer("r" + i, "Review #" + i));
            plugin.publish(many(42, "t", "working", "typing").concat(reviewers));
            compare([page.worldCols, page.worldRows], [cols, rows]);
            verify(page.world === world, "the same office");
            compare(Object.keys(page.world.seatOf).length, 48);
            compare(page.world.seats.length, 48);
            for (const id of ["t40", "t41"]) {
                verify(page.world.seatOf[id] === undefined, id + " has no desk");
                verify(actor(id).goal && actor(id).goal.x > page.world.xd, id + " takes a break");
            }
            walk(100);
            plugin.publish(many(2, "t", "working", "typing"));
            compare([page.worldCols, page.worldRows], [cols, rows]);
            checkFloor();
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

        // Where a row of open floor with open rows above and below it starts,
        // with nobody standing on it.
        function openFloor(length) {
            const w = page.world;
            const taken = {};
            for (const a of Object.values(page.actors))
                taken[a.ty * w.cols + a.tx] = true;
            for (let y = 1; y < w.rows - 1; y++) {
                for (let x = 0; x + length <= w.cols; x++) {
                    let open = true;
                    for (let dx = 0; dx < length && open; dx++) {
                        for (let dy = -1; dy <= 1; dy++)
                            open = open && page.walkable(x + dx, y + dy) && !taken[(y + dy) * w.cols + x + dx] && !page.claims[(y + dy) * w.cols + x + dx];
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

        // Where two people both want to stop, only one may: the tile is the
        // first one's, and the other stops beside it.
        function test_two_people_never_stop_on_one_tile() {
            plugin.publish(many(16, "t", "working", "typing"));
            checkFloor();
            const people = many(16, "t", "waiting");
            plugin.publish(people);
            const stops = {};
            for (const id of Object.keys(page.actors)) {
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

        // Someone spoken to on its way stops only where nobody else may, and the
        // speaker talks from the side it claimed, never where it happens to pass.
        function test_a_talk_stops_people_only_where_nobody_else_has_claimed() {
            plugin.publish([person("lead", "Lead", "working", "typing"), person("b", "B", "working", "typing"), person("c", "C", "working", "typing")]);
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
            page.claims[taken] = "b";
            runUntil(() => a.talk?.phase === "say", 4000, "the talk starts");
            verify(c.ty * W + c.tx !== taken, "C walks on past the spot that is someone else's");
            compare(page.claims[a.ty * W + a.tx], "lead", "the lead talks from the side it claimed");
            while (a.talk) {
                const here = c.ty * W + c.tx;
                if (c.next < 0)
                    verify(!page.claims[here] || page.claims[here] === "c", "C stands on a tile nobody else has");
                page.advance(1);
            }
            delete page.claims[taken];
            runUntil(() => arrived(c) && c.tx > page.world.xd, 2000, "C goes on to the break room");
        }

        // The one listening keeps the tile it stopped on for the whole talk:
        // anyone else looking for a spot, as every goal does, finds it taken,
        // so the listener stays put and the talk reaches its reply.
        function test_a_listener_keeps_its_tile_until_the_talk_ends() {
            plugin.publish([person("lead", "Lead", "working", "typing"), person("b", "B", "working", "typing"), person("c", "C", "working", "typing")]);
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
            if (page.free(spot, b)) {
                page.claim(b, spot);
                page.setGoal(b, Object.assign({
                    face: 0,
                    offY: 0,
                    pose: "stand",
                    kind: "spot"
                }, spot));
            }
            runUntil(() => a.talk?.phase === "reply", 400, "C replies");
            compare(page.claims[here], "c", "C holds the tile it listens on");
            verify(b.goal?.kind !== "spot", "B is not sent to C's tile");
            compare([c.tx, c.ty], [spot.x, spot.y], "C listens where it stopped");
            runUntil(() => !a.talk, 200, "the talk ends");
            verify(page.claims[here] === undefined || c.claim === here, "C lets go of the tile after the talk");
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
            page.claim(actor("c"), door);
            page.setGoal(actor("c"), Object.assign({
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
            compare(page.claims[here], undefined, "C's tile is free");
            compare(page.claims[ahead], undefined, "the tile C was headed for is free");
            compare(Object.values(page.claims).indexOf("c"), -1, "C holds no tile at all");
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
            page.decide(c, true);
            verify(c.claim !== here, "C is headed for its desk");
            while (a.talk) {
                compare(page.claims[here], "c", "C keeps the tile it listens on");
                compare([c.tx, c.ty], [here % page.world.cols, Math.floor(here / page.world.cols)], "C stays put");
                page.advance(1);
            }
            compare(page.claims[here], undefined, "C lets go of it after the talk");
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
                page.advance(1);
                const talking = [a, d].filter(p => p.talk?.to === "c");
                verify(talking.length <= 1, "one talks to C at a time");
                const now = talking[0];
                if (now && now.talk.phase !== "go") {
                    if (now.id !== last) {
                        last = now.id;
                        turns++;
                        here = c.ty * page.world.cols + c.tx;
                    }
                    compare(page.claims[here], "c", "C keeps its tile while " + now.id + " talks");
                }
            }
            compare(turns, 2, "both get their say");
            compare(last, "d", "D goes second");
        }

        // A speaker that finds every side of its listener taken keeps the spot
        // it had, rather than stop somewhere nobody holds for it.
        function test_a_speaker_with_no_side_free_keeps_its_spot() {
            plugin.publish(many(6, "t", "working", "typing"));
            const W = page.world.cols;
            const lead = actor("t0");
            const far = Object.values(page.actors).find(a => Math.abs(a.tx - lead.tx) + Math.abs(a.ty - lead.ty) > 2);
            verify(far, "someone sits away from the lead");
            const blocked = [];
            for (const [dx, dy] of [[-1, 0], [1, 0], [0, -1], [0, 1]]) {
                const i = (far.ty + dy) * W + far.tx + dx;
                if (page.walkable(far.tx + dx, far.ty + dy) && page.claims[i] === undefined) {
                    page.claims[i] = "someone";
                    blocked.push(i);
                }
            }
            plugin.publish(many(6, "t", "working", "typing"), [
                {
                    id: "talk-1",
                    from: "t0",
                    to: far.id,
                    kind: "message",
                    text: "Got a minute?",
                    at: new Date().toISOString()
                }
            ]);
            runUntil(() => !!lead.talk, 200, "the lead goes to talk");
            for (let i = 0; i < 200; i++) {
                page.advance(1);
                if (lead.next < 0 && lead.path.length === 0)
                    compare(page.claims[lead.ty * W + lead.tx], "t0", "the lead stands on a spot of its own");
            }
            compare(lead.talk.phase, "go", "the lead waits for a side to come free");
            for (const i of blocked)
                delete page.claims[i];
            runUntil(() => lead.talk?.phase === "say", 2000, "the talk starts once a side is free");
            compare(page.claims[lead.ty * W + lead.tx], "t0");
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

        // A view wide enough to fit the office past the most zoomed in scale
        // shows it at that scale, drawn directly rather than through a layer
        // of the whole office at more device pixels than that.
        function test_a_huge_view_fits_at_most_the_top_scale() {
            loader.width = 16000;
            loader.height = 10000;
            plugin.publish(many(1, "t", "working", "typing"));
            tryVerify(() => page.worldCols > 0 && page.fitScale > page.maxScale, 1000, "the view fits the office past the most zoomed in scale");
            fuzzyCompare(page.pixelScale, page.topScale, 1e-9);
            verify(!find("officeArt").layer.enabled, "the art is drawn directly");
            verify(!find("officeZoomIn").enabled, "zooming in further is off");
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
            for (let i = 0; i < 12 && page.pixelScale < page.topScale - 0.001; i++) {
                const before = page.pixelScale;
                page.zoomBy(1.25);
                // A step held back by the most zoomed in scale is not undone.
                if (page.pixelScale >= page.topScale - 0.001)
                    break;
                const after = page.pixelScale;
                page.zoomBy(1 / 1.25);
                fuzzyCompare(page.pixelScale, before, 1e-9, "out undoes in");
                page.zoomBy(1.25);
                fuzzyCompare(page.pixelScale, after, 1e-9, "in again goes as far");
            }
        }

        // The most zoomed in scale is a whole number of device pixels within
        // the most zoom allows, and the zoom-in button stops there.
        function test_the_most_zoomed_in_scale_is_whole_device_pixels() {
            plugin.publish(many(1, "t", "working", "typing"));
            tryVerify(() => page.worldCols > 0);
            const ratio = page.devicePixelRatio;
            fuzzyCompare(page.topScale * ratio, Math.round(page.topScale * ratio), 1e-9);
            verify(page.topScale <= page.maxScale + 1e-9 && page.topScale > page.maxScale - 1 / ratio, "as far in as whole device pixels go");
            page.zoom = page.maxScale / page.fitScale;
            fuzzyCompare(page.pixelScale, page.topScale, 1e-9);
            verify(!find("officeZoomIn").enabled, "zooming in further is off");
        }

        // Fit can sit between whole device pixels; the step from there goes to
        // the next whole one, not one past it.
        function test_a_step_from_between_whole_pixels_goes_to_the_next() {
            plugin.publish(many(1, "t", "working", "typing"));
            tryVerify(() => page.worldCols > 0);
            const ratio = page.devicePixelRatio;
            page.zoom = 3.55 / ratio / page.fitScale;
            page.zoomBy(1.25);
            fuzzyCompare(page.pixelScale * ratio, 4, 1e-9, "3.55 device pixels steps in to 4");
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
            while (page.pixelScale < page.topScale - 0.001 && steps < 40) {
                const before = page.pixelScale;
                page.zoomBy(1.25);
                verify(page.pixelScale > before, "each step zooms in");
                if (art.layer.enabled)
                    verify(page.drawScale * page.devicePixelRatio <= 4, "a layer is drawn only at a small scale");
                steps++;
            }
            fuzzyCompare(page.pixelScale, page.topScale, 1e-9);
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
            page.zoom = page.maxScale / page.fitScale;
            const scroller = find("officeScroller");
            const far = Object.values(page.actors).reduce((m, a) => a.tx + a.ty > m.tx + m.ty ? a : m);
            const hit = find("officePerson:" + far.id);
            const inView = () => {
                const r = hit.mapToItem(scroller, 0, 0, hit.width, hit.height);
                // Half a pixel either way is rounding, not out of view.
                return r.x >= -0.5 && r.y >= -0.5 && r.x + r.width <= scroller.width + 0.5 && r.y + r.height <= scroller.height + 0.5;
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
            page.advance(1);
            compare([actor("t4").tx, actor("t4").ty], page.world.entrance, "t4 walks in through the door");
            compare(page.deskCount, 4);
            let carried = false;
            runUntil(() => {
                carried = carried || Object.values(page.movers).some(m => m.carrying);
                if (seat.state !== "in")
                    verify(actor("t4").tx !== seat.x || actor("t4").ty !== seat.y, "t4 does not sit before its desk is there");
                return seat.state === "in";
            }, 1500, "the desk is set down");
            verify(carried, "a mover carried it");
            compare(page.deskCount, 5);
            runUntil(() => arrived(actor("t4")), 1500, "t4 reaches its desk");
            compare([actor("t4").tx, actor("t4").ty], [seat.x, seat.y]);
            runUntil(() => page.moves === 0, 1500, "the mover leaves");
            compare(Object.keys(page.movers).length, 0);
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
                page.advance(1);
                checkFloor();
                carrying = Math.max(carrying, Object.values(page.movers).filter(m => m.carrying).length);
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
            runUntil(() => Object.keys(page.movers).length > 0, 400, "a mover comes in");
            const w = page.world;
            const m = Object.values(page.movers)[0];
            verify(m.carrying, "it carries a desk");
            // It carries the desk along open floor instead of to its seat, past
            // t0 standing just north of the way.
            w.seats[m.job].mover = "";
            m.job = -1;
            m.path = [];
            const t0 = actor("t0");
            const [left, row] = openFloor(5);
            standAt(t0, left + 2, row - 1);
            page.place(m, left, row, true);
            m.goal = {
                x: left + 4,
                y: row,
                face: 0,
                offY: 0,
                pose: "stand",
                kind: "leave"
            };
            page.route(m);
            stood = {};
            let under = false;
            for (let i = 0; i < 600 && page.movers[m.id]; i++) {
                walk(1);
                if (!page.movers[m.id])
                    break;
                under = under || m.tx === left + 2 && m.ty === row;
                verify(!crosses(load(m), body(t0)), "the desk covers t0");
            }
            verify(under, "the mover passes just south of t0");
            verify(!page.movers[m.id], "the mover gets where it is going");
            compare([t0.tx, t0.ty], [left + 2, row - 1], "t0 stays where it stands");
        }

        // A newcomer waiting for its desk while every pod side is taken waits
        // on a tile nobody else is headed for.
        function test_newcomers_waiting_for_desks_never_share_a_tile() {
            plugin.publish([]);
            plugin.publish(many(16, "t", "working", "typing"));
            const check = () => {
                const at = {};
                for (const id of Object.keys(page.actors)) {
                    const goal = actor(id).goal;
                    if (goal?.kind !== "wait")
                        continue;
                    const key = goal.x + "," + goal.y;
                    verify(at[key] === undefined, id + " and " + at[key] + " both wait at " + key);
                    at[key] = id;
                    compare(page.claims[goal.y * page.world.cols + goal.x], id, id + " holds its claim");
                }
            };
            check();
            for (let i = 0; i < 400; i++) {
                page.advance(1);
                check();
            }
        }

        // A worker who came in when every desk it may take was taken waits in
        // the break room and sits down once a desk is free; one on a break
        // stays on it.
        function test_a_worker_without_a_desk_sits_down_once_it_gets_one() {
            const office = many(42, "t", "working", "typing");
            office[1] = person("t1", "t 1", "waiting");
            plugin.publish(office);
            verify(page.world.seatOf["t40"] === undefined, "t40 has no desk");
            verify(actor("t40").goal.x > page.world.xd, "t40 waits in the break room");
            const resting = actor("t1").goal;
            verify(resting.x > page.world.xd, "t1 takes a break");
            plugin.publish(office.filter(p => p.id !== "t0"));
            const seat = page.world.seatOf["t40"];
            verify(seat !== undefined, "t40 gets the desk t0 left");
            compare(actor("t40").goal.kind, "desk", "t40 heads for its desk");
            verify(actor("t1").goal === resting, "t1 stays on its break");
            runUntil(() => arrived(actor("t40")), 1500, "t40 reaches its desk");
            compare([actor("t40").tx, actor("t40").ty], [seat.x, seat.y]);
        }

        // Without a desk, a worker that plans or reads waits in the break room
        // too, rather than at a whiteboard or a bookshelf.
        function test_a_planner_without_a_desk_waits_in_the_break_room() {
            plugin.publish(many(40, "t", "working", "typing").concat([person("p", "Planner", "working", "planning"), person("r", "Reader", "working", "reading")]));
            for (const id of ["p", "r"]) {
                verify(page.world.seatOf[id] === undefined, id + " has no desk");
                verify(actor(id).goal.x > page.world.xd, id + " waits in the break room, not at a " + actor(id).goal.kind);
            }
        }

        // A talk to someone still outside the door waits for it to come in:
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
                page.advance(1);
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

        // Another machine's office starts with clean whiteboards.
        function test_another_machine_wipes_the_whiteboards() {
            plugin.publish([person("lead", "Lead", "working", "planning")]);
            runUntil(() => arrived(actor("lead")));
            const key = actor("lead").goal.board;
            const board = page.boardViews[key];
            const blank = board.progress;
            runUntil(() => board.progress > blank, 200, "the planner draws");
            plugin.environments = ["local", "lab"];
            page.environment = "lab";
            verify(page.boardViews[key] === board, "the same whiteboard");
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
                page.advance(40);
                plugin.publish(office(after));
                let inDoor = "", since = 0, ticks = 0;
                while ((page.moves || page.outside.length) && ticks < 2000) {
                    page.advance(1);
                    ticks++;
                    const there = Object.values(page.actors).concat(Object.values(page.movers)).find(a => a.tx === e[0] && a.ty === e[1] && a.next < 0)?.id ?? "";
                    since = there && there === inDoor ? since + 1 : 0;
                    inDoor = there;
                    verify(since < 40, there + " stands in the doorway");
                    checkFloor();
                }
                verify(ticks < 2000, before + " to " + after + ": everyone gets through, " + page.moves + " moves are left");
                page.advance(300);
                for (const id of Object.keys(page.actors)) {
                    const a = page.actors[id];
                    verify(a.tx >= 0 && a.goal && a.tx === a.goal.x && a.ty === a.goal.y, id + " gets where it is going");
                }
            }
        }

        // People coming in do not repaint the floor or the furniture.
        function test_people_coming_in_do_not_repaint_the_floor() {
            plugin.publish(many(4, "t", "working", "typing"));
            tryVerify(() => page.floorPaints > 0);
            const paints = page.floorPaints;
            const props = page.props, units = page.units;
            plugin.publish(many(12, "t", "working", "typing"));
            page.advance(200);
            plugin.publish(many(2, "t", "working", "typing"));
            page.advance(200);
            wait(50);
            compare(page.floorPaints, paints);
            verify(page.props === props && page.units === units, "the furniture is the same");
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
