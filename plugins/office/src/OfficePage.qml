pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks
import "LjosPlay"

// The Office page: a machine's threads as people in a pixel-art office. Each
// thread sits at a desk with the workers it delegated to in the same group of
// desks; some workers are cats and dogs. What a person does follows its agent:
// typing, running and testing at the computer, planning at a whiteboard, reading
// at a bookshelf, and waiting or idling at the desk, with a short break now
// and then. A talk in the `office` topic walks the speaker up to the other person with a speech bubble.
// Hover a person for who it is; click it to open its thread.
//
// The World is LjosPlay's (src/LjosPlay): it scales, paints each picture once
// and moves it. What is written here is the office: who sits where and what
// each state looks like, with the pictures in OfficeArt and Furniture. Until the floor and everyone on it are drawn, the
// page says the office is being set up.
Item {
    id: page

    property var plugin
    // environment → the last value of its `office` topic.
    property var byEnvironment: ({})
    // environment → its watch.
    property var watches: ({})
    property string environment: ""
    readonly property alias game: game
    readonly property alias staff: staff
    readonly property alias crew: crew
    readonly property var office: byEnvironment[environment] ?? null
    readonly property var people: office?.people ?? []
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color border: Theme.palette.color("border", "#27272a")
    readonly property color warningColor: Theme.palette.color("warning", "#f59e0b")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")

    // A host that does not stretch the page gives it this size.
    implicitWidth: 900
    implicitHeight: 600

    // Whether the office can be seen at all: the app neither hidden nor
    // suspended, its window not minimized. A window without focus still shows
    // it, so the office goes on for someone watching it from another window.
    property bool inSight: Qt.application.state !== Qt.ApplicationHidden
        && Qt.application.state !== Qt.ApplicationSuspended
        && Window.visibility !== Window.Minimized && Window.visibility !== Window.Hidden
    // Movers at work and desks waiting for one.
    property int moves: 0
    // The office as drawn: its size in tiles, its furniture, each desk and
    // chair, the screens of its computers and its whiteboards. Built again
    // only when the office changes size; the movers bring desks in and take
    // them out.
    property var screens: []
    property var boards: []
    property var deskMarks: []
    property int deskCount: 0
    // Counts the desks set down and carried away: a seat's state doesn't notify.
    property int deskTurns: 0
    // How many times the floor, and the desks' project marks, have been
    // painted.
    property int floorPaints: 0
    property int markPaints: 0
    // The sidebar's project icons; a desk shows its sitter's.
    readonly property var projectIcons: Shell.state.projectIcons ?? null
    property string hovered: ""

    // The room as built: pods, seats and who has which.
    property var world: null
    readonly property alias screenViews: screenViews
    readonly property alias markViews: markViews
    readonly property alias boardViews: boardViews
    property var jobs: []
    // People who came in while the doorway was busy wait outside, in order.
    // The doorway lets one person or mover through a step's time apart, from
    // doorOpensAt on.
    property var outside: []
    property real doorOpensAt: 0
    // The number of pods the office is closing down to, while the desks are
    // carried out of the rest; 0 when it is not (see closeRows()).
    property int closeTo: 0
    // The most people on a break at once.
    readonly property int breakRoomCap: 8
    property int moversHired: 0
    property var seen: ({})
    property var arrival: ({})
    property int arrivals: 0
    property bool primed: false
    // When the screens last changed and next change (see updateScreens()).
    property real screensSeen: 0
    property real screensAt: 0
    // What is on the screens draws from its own stream, so it never changes
    // where anyone goes.
    property var screenRng: game.random(0x5c4ee7)

    // What a waiting or idle person slacks off with on its screen: a
    // background and a few frames, each a list of [x, y, w, h, color] on the
    // 8×6 screen. A frame lasts a second (see updateScreens()).
    readonly property var slackArt: ({
            solitaire: {
                color: "#1f7a3a",
                frames: [[[0, 1, 2, 2, "#ffffff"], [3, 1, 2, 3, "#ffffff"], [6, 1, 2, 4, "#ffffff"], [0, 1, 1, 1, "#e53935"], [3, 1, 1, 1, "#212121"], [6, 1, 1, 1, "#e53935"]], [[0, 1, 2, 3, "#ffffff"], [3, 1, 2, 2, "#ffffff"], [6, 1, 2, 4, "#ffffff"], [0, 3, 1, 1, "#212121"], [3, 1, 1, 1, "#e53935"], [6, 1, 1, 1, "#e53935"]], [[1, 0, 2, 2, "#ffffff"], [4, 2, 2, 2, "#ffffff"], [6, 4, 2, 2, "#ffffff"], [1, 0, 1, 1, "#e53935"], [4, 2, 1, 1, "#212121"], [6, 4, 1, 1, "#e53935"]]]
            },
            snake: {
                color: "#0d1210",
                frames: [[[1, 4, 3, 1, "#5fd38a"], [3, 2, 1, 2, "#5fd38a"], [6, 1, 1, 1, "#ff5252"]], [[2, 4, 2, 1, "#5fd38a"], [3, 1, 1, 3, "#5fd38a"], [6, 1, 1, 1, "#ff5252"]], [[3, 2, 1, 3, "#5fd38a"], [3, 1, 3, 1, "#5fd38a"], [6, 1, 1, 1, "#ff5252"]], [[3, 2, 1, 2, "#5fd38a"], [3, 1, 4, 1, "#5fd38a"], [1, 4, 1, 1, "#ff5252"]]]
            },
            blocks: {
                color: "#151a33",
                frames: [[[0, 5, 3, 1, "#ffb74d"], [4, 5, 4, 1, "#4dd0e1"], [0, 4, 2, 1, "#ba68c8"], [6, 4, 2, 1, "#81c784"], [3, 0, 1, 2, "#ffd54f"]], [[0, 5, 3, 1, "#ffb74d"], [4, 5, 4, 1, "#4dd0e1"], [0, 4, 2, 1, "#ba68c8"], [6, 4, 2, 1, "#81c784"], [3, 2, 1, 2, "#ffd54f"]], [[0, 5, 3, 1, "#ffb74d"], [4, 5, 4, 1, "#4dd0e1"], [0, 4, 2, 1, "#ba68c8"], [6, 4, 2, 1, "#81c784"], [3, 3, 1, 3, "#ffd54f"]], [[0, 5, 2, 1, "#ba68c8"], [6, 5, 2, 1, "#81c784"], [3, 0, 3, 1, "#e57373"], [4, 1, 1, 1, "#e57373"]]]
            },
            cat: {
                color: "#202020",
                frames: [[[2, 2, 4, 2, "#f4a24c"], [2, 1, 1, 1, "#f4a24c"], [5, 1, 1, 1, "#f4a24c"], [6, 3, 1, 1, "#f4a24c"], [0, 5, 8, 1, "#555555"], [0, 5, 2, 1, "#ff3b3b"]], [[2, 2, 4, 2, "#f4a24c"], [2, 1, 1, 1, "#f4a24c"], [5, 1, 1, 1, "#f4a24c"], [6, 1, 1, 2, "#f4a24c"], [0, 5, 8, 1, "#555555"], [0, 5, 4, 1, "#ff3b3b"]], [[2, 1, 4, 2, "#f4a24c"], [2, 0, 1, 1, "#f4a24c"], [5, 0, 1, 1, "#f4a24c"], [6, 2, 1, 1, "#f4a24c"], [0, 5, 8, 1, "#555555"], [0, 5, 6, 1, "#ff3b3b"]]]
            },
            meme: {
                color: "#3a3a3a",
                frames: [[[1, 0, 6, 1, "#ffffff"], [3, 2, 2, 2, "#ffd54f"], [3, 3, 2, 1, "#5d4037"], [1, 5, 6, 1, "#ffffff"]], [[2, 0, 4, 1, "#ffffff"], [2, 2, 4, 2, "#7cb342"], [2, 1, 1, 1, "#7cb342"], [5, 1, 1, 1, "#7cb342"], [0, 5, 8, 1, "#ffffff"]]]
            },
            shopping: {
                color: "#f2f4f8",
                frames: [[[0, 0, 8, 1, "#ff9900"], [1, 2, 2, 2, "#4a90d9"], [5, 2, 2, 2, "#e57373"], [1, 4, 2, 1, "#9aa5b0"], [5, 4, 2, 1, "#9aa5b0"]], [[0, 0, 8, 1, "#ff9900"], [1, 2, 2, 2, "#4a90d9"], [5, 2, 2, 2, "#e57373"], [1, 4, 2, 1, "#9aa5b0"], [5, 4, 2, 1, "#ff9900"], [7, 0, 1, 1, "#e53935"]], [[0, 0, 8, 1, "#ff9900"], [1, 2, 2, 2, "#81c784"], [5, 2, 2, 2, "#ba68c8"], [1, 4, 2, 1, "#9aa5b0"], [5, 4, 2, 1, "#9aa5b0"], [7, 0, 1, 1, "#e53935"]]]
            }
        })

    // Whether this machine's office has been drawn once: its floor and the
    // sprite sheet of everyone in it. Until then the page says it is being set
    // up; newcomers after that just walk in. See settle().
    property bool settled: false

    readonly property var frame: ({
            stand: 0,
            walk1: 1,
            walk2: 2,
            sit: 3,
            type1: 4,
            type2: 5,
            cup: 6,
            sip: 7,
            sitCup: 8,
            sitSip: 9,
            raise1: 10,
            raise2: 11,
            book: 12,
            talk: 13,
            nap: 14
        })

    // ── Following the MC ────────────────────────────────────────────────────

    function follow() {
        const watches = {};
        for (const environment of page.plugin.environments) {
            watches[environment] = page.watches[environment] ?? page.plugin.watch("office", value => {
                const next = Object.assign({}, page.byEnvironment);
                next[environment] = value;
                page.byEnvironment = next;
            }, environment);
        }
        // An environment that left takes its last snapshot with it, so coming
        // back shows nothing stale before its new watch delivers.
        let cached = page.byEnvironment;
        for (const environment of Object.keys(page.watches)) {
            if (watches[environment] !== undefined)
                continue;
            page.plugin.unwatch(page.watches[environment]);
            if (cached[environment] !== undefined) {
                if (cached === page.byEnvironment)
                    cached = Object.assign({}, cached);
                delete cached[environment];
            }
        }
        page.watches = watches;
        if (cached !== page.byEnvironment)
            page.byEnvironment = cached;
        if (!page.plugin.environments.includes(page.environment))
            page.environment = page.plugin.environments[0] ?? "";
    }

    function environmentLabel(environment) {
        const known = (Shell.state.mcPlugins?.environments ?? []).find(each => each.id === environment);
        return known?.label ?? environment;
    }

    function openPerson(id) {
        if (id)
            page.plugin.openThread(id, page.environment);
    }

    onEnvironmentChanged: reset()
    onOfficeChanged: if (!resetting) take(office)
    Component.onCompleted: follow()

    Connections {
        target: page.plugin

        function onEnvironmentsChanged() {
            page.follow();
        }
    }

    // ── The floor plan ──────────────────────────────────────────────────────
    //
    // Rows 0–2 are the wall, row 3 the furniture along it, then groups of desks
    // ("pods") from row 6: a pod is chairs, two rows of desks, chairs. Teams (a
    // thread and the workers under it) share pods of 4×2 desks; a bigger team
    // takes several. Movers carry desks in through the entrance at the bottom
    // left and back out again. The break room is behind a wall with a door on
    // the right.
    //
    // The office is at least six pods in two rows, 48 desks of which the
    // review corner's 8 are for reviewers only, and grows by pods, so
    // everyone has a desk. It grows as soon as people outnumber the desks
    // they may take, to the grid of pods that shows biggest in the view (see
    // gridFor()), and shrinks once a pod's worth of desks would still be free
    // in a smaller one, after the desks in the pods it loses are carried out
    // (see closeRows()). It is painted again only when it changes size. Pods
    // are added at the bottom of a grid of the same width, so every tile keeps
    // its place; in one of another width people walk to where their desks now
    // stand (see rearrange()).

    function teamsOf(ids, byId) {
        const rootOf = id => {
            let p = byId[id];
            const seen = {};
            while (p && p.parentId && byId[p.parentId] && !seen[p.id]) {
                seen[p.id] = true;
                p = byId[p.parentId];
            }
            return p.id;
        };
        const teams = {}, roots = [];
        for (const id of ids) {
            const root = rootOf(id);
            if (!teams[root]) {
                teams[root] = [root];
                roots.push(root);
            }
            if (id !== root)
                teams[root].push(id);
        }
        return roots.map(root => teams[root]);
    }

    // Seats the teams at the office's pods, as id → seat. Everyone keeps the
    // seat they had while they stay, wherever it is, so nobody moves along
    // when someone else comes or goes. A newcomer takes a free
    // seat in its team's pod, or the nearest pod with room when that is full;
    // a new team takes a pod with room for all of it, and small teams share.
    // A team bigger than a pod takes as many as it needs; the office has a desk
    // for everyone (see buildWorld()). While the office is closing pods, they
    // take nobody, and whoever sat there moves to a desk in the rest.
    // Reviewers (`kind` "reviewer" in `byId`, their workers too, each by its
    // own kind) sit in the review corner, and once it is full at the desks
    // nearest it that nobody else needs. The corner is theirs alone: nobody
    // else ever needs a desk there, since the office grows first (see
    // sync()), and whoever sits there and is no reviewer leaves it. Should
    // someone else still find no free desk, a reviewer on a floor desk gives
    // it up.
    function seatTeams(teams, byId) {
        const w = page.world;
        const size = w.pods[0].seats.length;
        const open = pod => !page.closeTo || pod < page.closeTo;
        const before = {};
        for (const id of Object.keys(w.seatOf ?? {})) {
            if (open(w.seatOf[id].pod))
                before[id] = w.seatOf[id];
        }
        const seatOf = {};
        const taken = {};
        const room = pod => open(pod) ? w.pods[pod].seats.filter(seat => !taken[seat.index]).length : 0;
        const sit = (id, pod) => {
            const seat = w.pods[pod].seats.find(seat => !taken[seat.index]);
            taken[seat.index] = id;
            seatOf[id] = seat;
        };
        // Each member goes by its own kind: a team's reviewers and the rest
        // are chunked apart, though still one team for where they sit.
        const chunks = [], teamOf = [], reviewing = [];
        teams.forEach((team, t) => {
            for (const review of [false, true]) {
                const part = team.filter(id => (byId?.[id]?.kind === "reviewer") === review);
                for (let i = 0; i < part.length; i += size) {
                    chunks.push(part.slice(i, i + size));
                    teamOf.push(t);
                    reviewing.push(review);
                }
            }
        });
        // A pod is a chunk's own when it is the review corner exactly when the
        // chunk reviews.
        const own = (pod, c) => !!w.pods[pod].review === reviewing[c];
        // Everyone seated keeps their seat, but for an ordinary person in the
        // corner; a chunk's pod is where its first member keeping a seat sat,
        // and a team's home for each kind is its first chunk of that kind with
        // one.
        const keeps = (id, c) => !!before[id] && (reviewing[c] || !w.pods[before[id].pod].review);
        const homes = chunks.map((chunk, c) => before[chunk.find(id => keeps(id, c))]?.pod ?? -1);
        const kindOf = c => teamOf[c] + (reviewing[c] ? ":review" : ":floor");
        const teamHome = {};
        homes.forEach((home, c) => {
            if (home >= 0 && teamHome[kindOf(c)] === undefined)
                teamHome[kindOf(c)] = home;
        });
        // Where any seated part of team `t` sits, its floor part first.
        const seatedPart = t => teamHome[t + ":floor"] ?? teamHome[t + ":review"];
        // The pod with room for `need` nearest pod `near` (or the first with
        // room when there is no `near`), one of chunk `c`'s own kind first, or
        // only those when `only`; -1 when none has room. Ties go by index,
        // since sort() need not be stable.
        const away = (i, near) => near < 0 ? 0 : Math.abs(w.pods[i].x - w.pods[near].x) + Math.abs(w.pods[i].y - w.pods[near].y);
        const nearest = (near, need, c, only) => {
            const open = w.pods.map((_, i) => i).filter(i => room(i) >= need && (!only || own(i, c)));
            open.sort((a, b) => (own(b, c) - own(a, c)) || away(a, near) - away(b, near) || a - b);
            return open.length ? open[0] : -1;
        };
        chunks.forEach((chunk, c) => {
            for (const id of chunk) {
                const seat = before[id];
                if (keeps(id, c) && !taken[seat.index]) {
                    taken[seat.index] = id;
                    seatOf[id] = seat;
                }
            }
        });
        const spill = [];
        const corner = w.pods.findIndex(pod => pod.review);
        chunks.forEach((chunk, c) => {
            const home = homes[c] >= 0 && own(homes[c], c) ? homes[c] : -1;
            // Near the team's own kind: reviewers under an ordinary lead seated
            // on the floor start from the corner, not from their lead; the
            // rest start from wherever their team sits.
            const near = teamHome[kindOf(c)] ?? (reviewing[c] ? corner : seatedPart(teamOf[c]) ?? -1);
            let pod = home >= 0 ? home : nearest(near, chunk.length, c, true);
            // Reviewers who do not all fit in the corner still fill it first.
            if (pod < 0 && reviewing[c] && room(corner) > 0)
                pod = corner;
            for (const id of chunk) {
                if (seatOf[id])
                    continue;
                if (pod >= 0 && room(pod) > 0)
                    sit(id, pod);
                else
                    spill.push([id, pod >= 0 ? pod : homes[c] >= 0 ? homes[c] : near, c]);
            }
        });
        // Reviewers hot-desk: one on a floor desk gives it up to someone else
        // who has no desk of its own kind, the one nearest `near`, and spills
        // again from the corner.
        const chunkOf = {};
        chunks.forEach((chunk, c) => chunk.forEach(id => chunkOf[id] = c));
        const yieldTo = (id, near) => {
            const held = Object.keys(seatOf).filter(r => reviewing[chunkOf[r]] && !w.pods[seatOf[r].pod].review);
            if (!held.length)
                return;
            held.sort((a, b) => away(seatOf[a].pod, near) - away(seatOf[b].pod, near) || seatOf[a].index - seatOf[b].index);
            const r = held[0], seat = seatOf[r];
            delete seatOf[r];
            taken[seat.index] = id;
            seatOf[id] = seat;
            spill.push([r, corner, chunkOf[r]]);
        };
        // Those who did not fit sit at the nearest pod with a free desk, the
        // rest before reviewers, so a reviewer past the corner takes only a
        // floor desk nobody else needs: reviewers at one of their own kind
        // first, the rest never in the corner, and at a reviewer's floor desk
        // when there is no other.
        for (const review of [false, true]) {
            for (const [id, near, c] of spill) {
                if (reviewing[c] !== review)
                    continue;
                const pod = nearest(near, 1, c, !review);
                if (pod >= 0)
                    sit(id, pod);
                else if (!review)
                    yieldTo(id, near);
            }
        }
        return seatOf;
    }

    // The office: `count` pods of 4×2 desks, `across` of them to a row, the
    // walls, the furniture along them and the break room. The top pod by the
    // break room is the review corner, on a carpet of its own under a review
    // sign and the whiteboard where reviews are worked through. Every desk
    // starts out carried away (see furnish()).
    function buildWorld(across, count) {
        const podCols = 4;
        const down = Math.max(2, Math.ceil(count / across));
        const workW = across * podCols + 2 * (across - 1);
        const xd = 3 + workW + 2;
        const bx = xd + 1;
        const cols = officeCols(across);
        const rows = officeRows(down);
        const screens = [], boards = [], wall = [], seats = [], marks = [];
        const corner = 2;

        // Pods: a row of chairs, two rows of desks, a row of chairs. Each seat
        // has its own desk and chair, which come and go together. A desk's
        // place is kept for it while it is out, so the way around the pods
        // never changes; a seat is stepped onto only by whoever is going there.
        // A pod keeps its number, and so its desks, in every grid: pod 2, the
        // review corner, is always the top one by the break room.
        const placed = [];
        for (let index = 0; index < count; index++) {
            const slot = index === corner ? across - 1 : index === across - 1 ? corner : index;
            const y0 = 6 + 6 * Math.floor(slot / across);
            const x = 3 + slot % across * (podCols + 2);
            const chair = game.pick(game.random(game.hash("chair" + index)), ["#3d4a63", "#4a3d63", "#2f5b52", "#63413d", "#3d5563"]);
            const podSeats = [];
            for (let i = 0; i < podCols; i++) {
                for (const north of [true, false]) {
                    const seat = {
                        index: seats.length + podSeats.length,
                        x: x + i,
                        y: north ? y0 : y0 + 3,
                        deskY: north ? y0 + 1 : y0 + 2,
                        face: north ? 0 : 3,
                        offY: north ? 5 : -3,
                        pod: index,
                        chair: chair,
                        screen: north ? "" : index + ":" + i,
                        state: "out",
                        mover: ""
                    };
                    podSeats.push(seat);
                    if (!north)
                        screens.push({
                            key: seat.screen,
                            seat: seat.index,
                            x: seat.x * 16 + 4,
                            y: seat.deskY * 16 + 1,
                            z: (y0 + 3) * 16 + 1
                        });
                    // Its sitter's project: on the back of the monitor
                    // facing us, or on the back of the chair facing away.
                    marks.push({
                        key: "mark:" + seat.index,
                        seat: seat.index,
                        x: seat.x * 16 + 3,
                        y: north ? seat.deskY * 16 + 4 : seat.y * 16 + 5,
                        w: 9,
                        h: 7,
                        z: north ? (y0 + 3) * 16 + 1 : (y0 + 4) * 16 + 2
                    });
                }
            }
            placed.push({
                x: x,
                y: y0,
                cols: podCols,
                members: [],
                seats: podSeats,
                review: index === corner
            });
            for (const seat of podSeats)
                seats.push(seat);
        }

        // Along the top wall: bookshelves, whiteboards and plants, and the
        // review corner's whiteboard over it, whatever would hang there.
        const sequence = ["plant", "shelf", "board", "shelf", "board", "plant", "shelf", "board"];
        const reviewX = placed[corner].x - 1;
        let hung = false;
        let wx = 2;
        for (let i = 0; ; i++) {
            let kind = sequence[i % sequence.length];
            let w = kind === "shelf" ? 2 : kind === "board" ? 3 : 1;
            if (!hung && wx + w > reviewX) {
                kind = "board";
                w = 3;
                wx = Math.max(wx, reviewX);
            }
            if (wx + w > xd - 1)
                break;
            const piece = {
                kind: kind,
                tx: wx,
                columns: w,
                board: "",
                review: false
            };
            if (kind === "board") {
                piece.board = "board:" + boards.length;
                piece.review = !hung && wx >= reviewX;
                hung = hung || piece.review;
                boards.push({
                    key: piece.board,
                    x: wx * 16 + 5,
                    y: 64 - 40 + 5,
                    z: 64.5,
                    review: piece.review
                });
            }
            wall.push(piece);
            wx += w + 1;
        }

        const review = placed[corner];
        return {
            cols: cols,
            rows: rows,
            down: down,
            across: across,
            xd: xd,
            bx: bx,
            pods: placed,
            // The review corner's carpet, in tiles: from beside the pod to
            // the break room's wall, the whiteboard to the walkway below.
            review: {
                x: review.x - 1,
                y: 4,
                w: xd - review.x + 1,
                h: review.y + 5 - 4
            },
            marks: marks,
            seats: seats,
            seatOf: {},
            wall: wall,
            screens: screens,
            boards: boards,
            door: [xd, 5],
            entrance: [2, rows - 2]
        };
    }

    // ── Who is in the office ────────────────────────────────────────────────

    // Another machine's office: everyone leaves at once and its people come
    // in where they belong, at desks that are simply there. The room stays,
    // its whiteboards wiped.
    // Another machine's office while the one before it is cleared: reset() takes
    // it itself at its end (hal-c2/ljos-ui#746).
    property bool resetting: false

    function reset() {
        page.resetting = true;
        staff.keep([]);
        crew.keep([]);
        page.hovered = "";
        page.jobs = [];
        page.outside = [];
        page.doorOpensAt = 0;
        page.closeTo = 0;
        if (page.world) {
            page.world.seatOf = {};
            for (const seat of page.world.seats) {
                seat.mover = "";
                setDesk(seat, false);
            }
        }
        for (let i = 0; i < boardViews.count; i++) {
            const board = boardViews.itemAt(i);
            if (board)
                board.progress = board.blank;
        }
        countMoves();
        page.seen = {};
        page.arrival = {};
        game.claims = {};
        page.primed = false;
        page.settled = false;
        // `office` still holds the last machine's value while its change is
        // handled here.
        take(page.byEnvironment[page.environment] ?? null);
        page.resetting = false;
    }

    function take(value) {
        // An empty office has no clock running, and nothing to catch up on.
        if (game.shown && !game.running)
            game.tickedAt = Date.now();
        const people = value?.people ?? [];
        sync(people);
        // A closure with nothing left to carry out closes now: the clock may
        // not run again for an office nobody is in.
        if (page.closeTo)
            closeRows();
        hear(value?.talks ?? []);
        page.primed = value !== null && value !== undefined;
        updateWalking();
        settle(value);
    }

    // The clock stood still, the page out of sight or the machine asleep: what
    // happened meanwhile is over, and the office is drawn as it is now, with
    // everyone and every desk where they belong and nothing from then said.
    function catchUp() {
        if (!page.primed)
            return;
        for (const actor of Object.values(game.actors)) {
            if (actor.talk)
                game.talks.end(actor);
            actor.queue = [];
            actor.bubble = "";
        }
        for (const id of Object.keys(crew.members))
            removeMover(id);
        page.jobs = [];
        page.outside = [];
        page.doorOpensAt = 0;
        page.primed = false;
        take(page.office);
        for (const actor of Object.values(game.actors)) {
            if (actor.goal) {
                actor.place(actor.goal.x, actor.goal.y, false);
                actor.path = [];
            }
        }
        updateWalking();
    }

    // The office is settled once `value`, this machine's office, has been
    // drawn. Asked only where the people match `value`: after taking it and
    // after a paint, never from a binding, which sees the steps in between.
    function settle(value) {
        if (!page.settled && page.world && value && page.floorPaints > 0 && game.sheetsPending === 0)
            page.settled = true;
    }

    // The size in tiles of an office `across` pods wide and `down` deep.
    function officeCols(across) {
        return 6 * across + 15;
    }

    function officeRows(down) {
        return 6 * down + 7;
    }

    // The grid for at least `pods` pods, at least two rows of them, that
    // shows biggest when fitted to the view (see fitScale): it grows sideways
    // in a wide view and down in a tall one, down to a single column in a
    // narrow one, and has the fewest pods of those that show as big. Before
    // the view has a size, it is three across.
    function gridFor(pods) {
        const vw = game.width - 8, vh = game.height - 8;
        let best = null;
        for (let across = 1; across <= Math.max(3, Math.ceil(pods / 2)); across++) {
            const down = Math.max(2, Math.ceil(pods / across));
            const fit = vw > 0 && vh > 0 ? Math.min(vw / (officeCols(across) * 16), vh / (officeRows(down) * 16)) : across === 3 ? 1 : 0;
            if (!best || fit > best.fit || fit === best.fit && across * down < best.pods)
                best = {
                    across: across,
                    pods: across * down,
                    fit: fit
                };
        }
        return best;
    }

    function sync(people) {
        // The review corner's eight desks are only for reviewers, and the
        // reviewers it has no room for take ordinary desks. The office grows
        // to a full grid when it runs out of desks, and closes pods once a
        // smaller grid would leave a pod's worth free. A reviewer who already
        // sits at an ordinary desk keeps it (see seatTeams()), so it needs one
        // of those rather than one in the corner.
        const w = page.world;
        const floor = p => {
            const seat = w?.seatOf?.[p.id];
            return !!seat && !w.pods[seat.pod]?.review;
        };
        const reviewers = people.filter(p => p.kind === "reviewer" && !floor(p)).length;
        const desks = people.length - reviewers + Math.max(8, reviewers);
        const need = Math.max(6, Math.ceil(desks / 8));
        const grid = gridFor(need);
        if (!w || need > w.pods.length || !page.primed && (grid.across !== w.across || grid.pods !== w.pods.length)) {
            page.closeTo = 0;
            build(grid.across, grid.pods);
        } else {
            const keep = gridFor(Math.max(6, Math.ceil((desks + 8) / 8))).pods;
            page.closeTo = keep < w.pods.length ? keep : 0;
        }
        const byId = {};
        for (const person of people)
            byId[person.id] = person;
        staff.keep(people);
        if (page.hovered && !game.actors[page.hovered])
            page.hovered = "";
        for (const person of people) {
            if (page.arrival[person.id] === undefined)
                page.arrival[person.id] = page.arrivals++;
        }
        const order = people.map(p => p.id).sort((a, b) => page.arrival[a] - page.arrival[b]);
        layout(teamsOf(order, byId), byId);
        staff.fill(people);
        for (const actor of Object.values(game.actors)) {
            if (actor.tx < 0)
                arrive(actor);
            actor.decide(false);
        }
        page.deskTurns++;
    }

    // Builds the office with `count` pods, `across` to a row, taking over
    // what goes on in the one before, if any. The whiteboards stay, with what
    // is drawn on them, while the office keeps its width.
    function build(across, count) {
        const old = page.world;
        const w = buildWorld(across, count);
        game.columns = w.cols;
        game.rows = w.rows;
        // The furniture follows at once, and says which tiles it takes.
        page.world = w;
        game.compile();
        if (old)
            carry(old, w);
        page.screens = w.screens;
        if (!old || old.across !== across)
            page.boards = w.boards;
        page.deskMarks = w.marks;
        page.deskCount = w.seats.filter(deskShown).length;
        page.deskTurns++;
        floor.requestPaint();
    }

    // Moves the desks, who has them and everyone in the office over from
    // `old` to the bigger or smaller `w`. A desk keeps its number and its
    // owner. While the office keeps its width tiles keep their places, and
    // whoever stands, steps or is headed where the smaller office ends goes on
    // from the nearest floor; movers on their way out head for the new
    // entrance.
    function carry(old, w) {
        for (const seat of w.seats) {
            const was = old.seats[seat.index];
            if (was) {
                seat.state = was.state;
                seat.mover = was.mover;
            }
        }
        for (const id of Object.keys(old.seatOf)) {
            const seat = w.seats[old.seatOf[id].index];
            if (seat)
                w.seatOf[id] = seat;
        }
        w.pods.forEach((pod, i) => pod.members = old.pods[i]?.members ?? []);
        page.jobs = page.jobs.filter(i => i < w.seats.length);
        if (old.across !== w.across) {
            rearrange(old, w);
            return;
        }
        const n = w.cols * w.rows;
        const lost = i => i >= n || game.plan().grid[i] === 1;
        for (const a of everyone()) {
            if (a.tx < 0)
                continue;
            const leaving = a.goal?.kind === "leave";
            if (a.goal && !leaving && lost(a.goal.y * w.cols + a.goal.x)) {
                game.release(a);
                a.goal = null;
                a.path = [];
            }
            const moved = lost(a.ty * w.cols + a.tx) || a.next >= 0 && lost(a.next);
            // A mover on its way out where the office ends has left.
            if (moved && leaving) {
                removeMover(a.key);
                continue;
            }
            if (moved)
                a.place(a.tx, a.ty, true);
            if (leaving)
                leave(a);
            else if (a.goal && (moved || a.path.some(lost)))
                a.route();
        }
    }

    // In an office of another width the desks stand elsewhere, and the break
    // room moves along with whoever is in it. Everyone else walks on from
    // where it is to where it was going: people to their own desk, movers to
    // the desk they carry. Whoever is left on furniture, or past the smaller
    // office's edge, steps to the nearest floor first. Before the office is
    // first shown, people are simply there.
    function rearrange(old, w) {
        game.claims = {};
        const dx = w.xd - old.xd;
        const across = x => x >= old.xd ? x + dx : x;
        for (const a of everyone()) {
            a.claim = -1;
            a.hold = -1;
            if (a.tx < 0)
                continue;
            // Whoever is in the break room, on its door or stepping onto the
            // door moves with it, the step it takes and all.
            const room = a.tx >= old.xd || a.next >= 0 && a.next % old.cols >= old.xd;
            const shift = room ? dx : 0;
            const nx = a.next >= 0 ? a.next % old.cols + shift : -1;
            const ny = a.next >= 0 ? Math.floor(a.next / old.cols) : -1;
            a.px += shift * 16;
            a.tx += shift;
            a.next = nx >= 0 && nx < w.cols && ny < w.rows ? ny * w.cols + nx : -1;
            a.path = [];
            // A step through the break room's door that the door moved away
            // from is not finished: it goes on from the tile it set out from.
            if (a.tx >= w.cols || a.ty >= w.rows || a.next >= 0 && Math.abs(nx - a.tx) + Math.abs(ny - a.ty) !== 1)
                a.place(a.tx, a.ty, true);
            // Whoever was out in the office where the break room now is
            // steps back to the office's floor by its wall: it goes into the
            // break room only when let in (see restless()).
            if (!room && (a.tx >= w.xd || a.next >= 0 && a.next % w.cols >= w.xd)) {
                const free = game.nearestFree(w.xd - 1, a.ty, a.key, w.xd) ?? w.entrance.slice();
                a.place(free[0], free[1], false);
            }
            const goal = a.goal;
            if (a.manual) {
                if (a.job >= 0) {
                    const seat = w.seats[a.job];
                    a.goal = Object.assign({}, goal, {
                        x: seat.x,
                        y: seat.y,
                        face: seat.face
                    });
                } else {
                    leave(a);
                }
            } else if (a.talk) {
                // Its speaker finds a side of it again (see Talks.step()), or,
                // talking already, keeps the one it talks from (below).
                a.goal = null;
                a.talk.target = -1;
            } else if (a.plan === "break" && goal && goal.x >= old.xd) {
                a.goal = Object.assign({}, goal, {
                    x: across(goal.x)
                });
                if (goal.partner !== undefined)
                    a.goal.partner = Math.floor(goal.partner / old.cols) * w.cols + across(goal.partner % old.cols);
                game.claim(a, a.goal);
            } else {
                // Someone resting who still sits at its desk rests on to the
                // same moment; one that has to move starts again once there.
                const until = a.plan === "rest" ? a.until : Infinity;
                a.goal = null;
                a.plan = "";
                a.decide(true);
                if (a.plan === "rest" && a.goal?.seat && a.tx === a.goal.x && a.ty === a.goal.y && a.next < 0)
                    a.until = until;
            }
            if (!page.primed && a.goal && !a.manual) {
                a.place(a.goal.x, a.goal.y, false);
                a.path = [];
                continue;
            }
            // A step goes on only between tiles still open to it: the one it
            // steps onto is floor or where it is going, and the one it steps
            // from no wall or furniture, a seat it is leaving aside.
            const on = a.next >= 0 ? a.next : a.ty * w.cols + a.tx;
            const mine = a.goal && on === a.goal.y * w.cols + a.goal.x;
            if (game.plan().grid[on] !== 0 && !mine || a.next >= 0 && game.plan().grid[a.ty * w.cols + a.tx] === 1)
                a.place(a.tx, a.ty, true);
            a.route();
        }
        // Two still side by side and talking claim their tiles again, or the
        // speaker moves on (see Talks.carryOn()).
        for (const a of everyone()) {
            const other = a.talk && a.talk.phase !== "go" ? game.actors[a.talk.to] : null;
            if (other && a.next < 0 && Math.abs(a.tx - other.tx) + Math.abs(a.ty - other.ty) === 1)
                game.talks.carryOn(a, other);
        }
    }

    // Once the desks in the pods the office is closing are all carried out,
    // and nobody listens at one of their seats or in the rows a shorter
    // office loses, the office shrinks to the rest.
    function closeRows() {
        const w = page.world;
        const first = page.closeTo * w.pods[0].seats.length;
        const seats = {};
        for (let i = first; i < w.seats.length; i++) {
            if (w.seats[i].state !== "out" || w.seats[i].mover)
                return;
            seats[w.seats[i].y * w.cols + w.seats[i].x] = true;
        }
        const count = page.closeTo;
        const gone = (officeRows(Math.max(2, Math.ceil(count / gridFor(count).across))) - 1) * w.cols;
        if (Object.values(game.actors).some(a => seats[a.hold] || a.hold >= gone))
            return;
        page.closeTo = 0;
        build(gridFor(count).across, count);
    }

    // A view of another size may show the office bigger in another grid: it
    // is built again only when the best number of pods to a row changes. A
    // view with no size keeps the office as it is. An office closing pods
    // works out again how many to close down to, in a grid for the new view,
    // even when it keeps its own.
    function refit() {
        const w = page.world;
        if (!w || game.width <= 8 || game.height <= 8)
            return;
        const across = gridFor(w.pods.length).across;
        if (across !== w.across)
            build(across, w.pods.length);
        else if (!page.closeTo)
            return;
        if (page.closeTo)
            take(page.office);
        page.deskTurns++;
        updateWalking();
    }

    function layout(teams, byId) {
        const w = page.world;
        const seatOf = seatTeams(teams, byId);
        const at = {};
        for (const id of Object.keys(seatOf))
            at[seatOf[id].index] = id;
        for (const pod of w.pods)
            pod.members = pod.seats.filter(seat => at[seat.index]).map(seat => at[seat.index]);
        w.seatOf = seatOf;
        furnish();
        // Seats move between people as people come and go; whoever was headed
        // for a desk, or waiting for one, that is no longer theirs plans again.
        for (const id of Object.keys(game.actors)) {
            const actor = game.actors[id];
            const goal = actor.goal;
            if (goal?.kind !== "desk" && goal?.kind !== "wait")
                continue;
            const seat = seatOf[id];
            if (!seat || seat.index !== goal.desk || (goal.kind === "wait") !== (seat.state !== "in"))
                actor.goal = null;
        }
    }

    // ── Desks and the movers who carry them ─────────────────────────────────

    // Brings in the desks people have been given and takes out the ones nobody
    // has. Before the office is first shown the desks are simply there.
    function furnish() {
        const w = page.world;
        const needed = {};
        for (const seat of Object.values(w.seatOf))
            needed[seat.index] = true;
        for (const seat of w.seats) {
            const need = !!needed[seat.index];
            if (!page.primed) {
                setDesk(seat, need);
            } else if (need && seat.state === "out") {
                seat.state = "coming";
                page.jobs.push(seat.index);
            } else if (need && seat.state === "leaving") {
                seat.state = "in";
                callOff(seat);
            } else if (!need && seat.state === "in") {
                seat.state = "leaving";
                page.jobs.push(seat.index);
            } else if (!need && seat.state === "coming") {
                // A mover already carrying it takes it back out.
                seat.state = "out";
                callOff(seat);
            }
        }
        countMoves();
        if (page.jobs.length)
            game.walking = true;
    }

    // A move that is no longer wanted: not started, or its mover heads out.
    function callOff(seat) {
        page.jobs = page.jobs.filter(i => i !== seat.index);
        const mover = crew.members[seat.mover];
        seat.mover = "";
        if (mover) {
            mover.job = -1;
            leave(mover);
        }
    }

    // Sets a desk down at its seat or takes it away; its owner, if waiting for
    // it, sits down.
    function setDesk(seat, on) {
        const w = page.world;
        const was = deskShown(seat);
        seat.state = on ? "in" : "out";
        if (on !== was) {
            page.deskCount += on ? 1 : -1;
            page.deskTurns++;
        }
        if (!on)
            return;
        const owner = Object.keys(w.seatOf).find(id => w.seatOf[id] === seat);
        const actor = owner ? game.actors[owner] : null;
        if (actor && actor.goal?.kind === "wait")
            actor.decide(true);
    }

    function deskShown(seat) {
        return seat.state === "in" || seat.state === "leaving";
    }

    function deskIn(index) {
        const seat = page.deskTurns >= 0 ? page.world?.seats[index] : null;
        return !!seat && deskShown(seat);
    }

    // ── The project on each desk ────────────────────────────────────────────

    // Who has each seat, as of the desks' last turn.
    readonly property var owners: {
        const seatOf = page.deskTurns >= 0 ? page.world?.seatOf ?? {} : {};
        const owners = {};
        for (const id of Object.keys(seatOf))
            owners[seatOf[id].index] = id;
        return owners;
    }

    // What a desk shows: its owner's project. Reviewers hot-desk, so the
    // corner's desks and any desk a reviewer has show none.
    function signAt(index) {
        const id = page.owners[index];
        const person = id ? game.actors[id]?.person : null;
        const w = page.world;
        const seat = w?.seats[index];
        if (!person || !seat || person.kind === "reviewer" || w.pods[seat.pod]?.review)
            return null;
        return signOf(person);
    }

    // A person's project as the sidebar draws it: its monogram in its colour,
    // its emoji, or its logo over the monogram. A symbol shows as the
    // project's colour with its first letter, and a project the sidebar has
    // no icon for as its first letter, uncoloured.
    function signOf(person) {
        const icon = page.projectIcons?.[page.environment + ":" + person.projectId] ?? null;
        const first = String(person.project ?? "").trim().charAt(0).toUpperCase();
        const kind = icon?.kind === "emoji" || icon?.kind === "image" ? icon.kind : "tile";
        let tint = String(icon?.tint ?? "");
        if (/^#[0-9a-fA-F]{8}$/.test(tint))
            tint = "#" + tint.slice(3);
        return {
            kind: icon || first ? kind : "",
            label: String(icon?.kind === "lucide" ? "" : icon?.text ?? "") || first,
            tint: /^#[0-9a-fA-F]{6}$/.test(tint) ? tint.toLowerCase() : "#8b919e",
            emoji: kind === "emoji" ? String(icon.emoji ?? "") : "",
            url: kind === "image" ? String(icon.url ?? "") : ""
        };
    }

    // A hex colour `k` of the way from `a` to `b`.
    function mix(a, b, k) {
        const x = parseInt(a.slice(1), 16), y = parseInt(b.slice(1), 16);
        return "#" + [16, 8, 0].map(at => Math.round(((x >> at) & 255) * (1 - k) + ((y >> at) & 255) * k).toString(16).padStart(2, "0")).join("");
    }

    // A desk's mark: the sidebar's raised tile in the project's colour, with
    // its letters in pixels. An emoji is drawn over it by its delegate.
    function paintMark(ctx, view) {
        const w = view.width, h = view.height;
        ctx.clearRect(0, 0, w, h);
        if (!view.kind)
            return;
        artist.rect(ctx, mix("#1c1f26", view.tint, 0.22), 0, 0, w, h);
        if (view.kind === "emoji")
            return;
        const glyphs = artist.letters(view.label)?.slice(0, 2);
        if (glyphs?.length)
            artist.paintLetters(ctx, glyphs, Math.floor((w - glyphs.length * 4 + 1) / 2), Math.floor((h - 5) / 2), view.tint);
        else
            artist.rect(ctx, view.tint, Math.floor(w / 2) - 1, Math.floor(h / 2) - 1, 3, 3);
    }

    function everyone() {
        return Object.values(game.actors).concat(Object.values(crew.members));
    }

    function countMoves() {
        page.moves = page.jobs.length + crew.count;
    }

    // Someone to carry a desk walks in when the doorway is free; four work
    // at once.
    function hire() {
        const w = page.world;
        const e = w.entrance;
        if (!page.jobs.length || crew.count >= 4 || !throughDoor())
            return;
        const seat = w.seats[page.jobs.shift()];
        const id = "mover:" + page.moversHired++;
        crew.fill([{
                id: id,
                job: seat.index,
                carrying: seat.state === "coming",
                chair: seat.chair
            }]);
        const mover = crew.members[id];
        seat.mover = id;
        mover.place(e[0], e[1], false);
        mover.goal = {
            x: seat.x,
            y: seat.y,
            face: seat.face,
            offY: 0,
            pose: "stand",
            kind: "move"
        };
        mover.route();
        countMoves();
    }

    // A mover walks to the desk's seat, sets the desk down or picks it up,
    // and walks out again.
    function stepMover(mover, dt) {
        const w = page.world;
        const seat = mover.job >= 0 ? w.seats[mover.job] : null;
        const there = mover.goal && mover.tx === mover.goal.x && mover.ty === mover.goal.y && mover.next < 0;
        if (there && !seat) {
            removeMover(mover.key);
            return false;
        }
        if (there) {
            mover.path = [];
            mover.dir = seat.face;
            if (seat.state === "coming") {
                mover.carrying = false;
                finish(mover, seat);
                setDesk(seat, true);
            } else {
                setDesk(seat, false);
                mover.carrying = true;
                finish(mover, seat);
            }
        }
        const moving = mover.step(dt);
        // Out through the entrance, it is gone at once.
        if (!seat && mover.goal && mover.tx === mover.goal.x && mover.ty === mover.goal.y && mover.next < 0) {
            removeMover(mover.key);
            return false;
        }
        mover.frame = mover.next >= 0 ? mover.walkFrames[Math.floor(mover.dist / 5) % 4] : 0;
        return moving || mover.path.length > 0;
    }

    function finish(mover, seat) {
        seat.mover = "";
        mover.job = -1;
        leave(mover);
    }

    function leave(mover) {
        const e = page.world.entrance;
        mover.goal = {
            x: e[0],
            y: e[1],
            face: 0,
            offY: 0,
            pose: "stand",
            kind: "leave"
        };
        mover.route();
    }

    function removeMover(id) {
        const mover = crew.members[id];
        if (!mover)
            return;
        const w = page.world;
        if (mover.job >= 0 && w.seats[mover.job].mover === id)
            w.seats[mover.job].mover = "";
        crew.keep(Object.keys(crew.members).filter(each => each !== id));
        countMoves();
    }

    // Movers wear the moving company's orange and its navy cap.
    function moverLook(id) {
        return Object.assign(artist.lookFor({
            id: id,
            parentId: null
        }), {
            top: "tee",
            shirt: "#d9822b",
            accent: "#2f4a6b",
            pants: "#2f4a6b",
            shoes: "#3a2a20",
            hat: "cap",
            headphones: false,
            bow: false,
            lanyard: false
        });
    }

    // A new person walks in through the door, waiting outside while someone
    // else goes through; the first people on the page are already where they
    // belong.
    function arrive(actor) {
        if (!page.primed) {
            actor.decide(true);
            const goal = actor.goal;
            if (goal) {
                actor.place(goal.x, goal.y, false);
                actor.path = [];
                return;
            }
        }
        if (!page.outside.includes(actor.key))
            page.outside.push(actor.key);
    }

    // Lets one through the doorway if the last went through a step ago, so
    // people and movers come in one after another rather than in a heap.
    function throughDoor() {
        if (game.now < page.doorOpensAt)
            return false;
        page.doorOpensAt = game.now + 400;
        return true;
    }

    // The next person waiting outside walks in once the doorway is free.
    function letIn() {
        while (page.outside.length && !game.actors[page.outside[0]])
            page.outside.shift();
        if (!page.outside.length || !throughDoor())
            return;
        const actor = game.actors[page.outside.shift()];
        const e = page.world.entrance;
        actor.place(e[0], e[1], false);
        actor.decide(true);
        game.walking = true;
    }

    // ── What each person does ───────────────────────────────────────────────

    function seatGoal(actor, pose) {
        const seat = page.world.seatOf[actor.key];
        // Everyone has a desk (see buildWorld()); one not yet seated plans
        // again in a moment (see Actor.think()).
        if (!seat) {
            game.release(actor);
            return null;
        }
        // A desk someone still listens at is theirs until the talk ends (see
        // deskFreed()).
        const holder = game.actors[game.claims[seat.y * page.world.cols + seat.x]];
        if (seat.state !== "in" || holder && holder !== actor && holder.hold === seat.y * page.world.cols + seat.x)
            return waitGoal(actor, seat);
        game.claim(actor, seat);
        return {
            x: seat.x,
            y: seat.y,
            face: seat.face,
            offY: pose === "ask" ? (seat.face === 0 ? 2 : 0) : seat.offY,
            pose: pose,
            kind: "desk",
            seat: true,
            desk: seat.index
        };
    }

    // Beside the pod, out of the way of its seats, while the desk is carried in.
    function waitGoal(actor, seat) {
        const w = page.world;
        const pod = w.pods[seat.pod];
        const options = [];
        for (const y of [pod.y + 1, pod.y + 2]) {
            for (const x of [pod.x - 1, pod.x + pod.cols, pod.x - 2, pod.x + pod.cols + 1]) {
                if (game.walkable(x, y) && game.free({
                    x: x,
                    y: y
                }, actor))
                    options.push([x, y]);
            }
        }
        const far = ([x, y]) => Math.abs(x - seat.x) + Math.abs(y - seat.y);
        options.sort((a, b) => far(a) - far(b));
        const spot = options[0] ?? game.nearestFree(pod.x - 1, pod.y + 1, actor.key);
        // With nowhere to wait, it plans again in a moment (see Actor.think()).
        if (!spot) {
            game.release(actor);
            return null;
        }
        const goal = {
            x: spot[0],
            y: spot[1],
            face: spot[0] < pod.x ? 2 : 1,
            offY: 0,
            pose: "stand",
            kind: "wait",
            desk: seat.index
        };
        game.claim(actor, goal);
        return goal;
    }

    function spotGoal(actor, kind, pose) {
        let options = game.plan().spots.filter(s => s.kind === kind && game.free(s, actor));
        // Reviewers plan at the review corner's whiteboard and everyone else
        // at the others, each at the other's when its own is taken.
        const own = options.filter(s => !!s.review === (actor.person?.kind === "reviewer"));
        if (own.length)
            options = own;
        if (!options.length)
            return null;
        const current = options.find(s => s.x === actor.goal?.x && s.y === actor.goal?.y);
        const spot = current ?? game.pick(game.rng, options);
        game.claim(actor, spot);
        return Object.assign({}, spot, {
            pose: pose ?? spot.pose
        });
    }

    function workGoal(actor) {
        const activity = actor.person.activity ?? "";
        const spot = activity === "planning" ? spotGoal(actor, "board") : activity === "reading" ? spotGoal(actor, "shelf") : null;
        return spot ?? seatGoal(actor, activity === "typing" || activity === "running" || activity === "testing" || activity === "browsing" ? "type" : "sit");
    }

    // Somewhere in the break room, chosen by weight among the free spots. After
    // the coffee machine or the water cooler, a person sits down with the cup.
    function breakGoal(actor, idle) {
        const pet = actor.look.pet;
        const weights = pet ? {
            petBed: 5,
            couch: 2,
            armchair: 1,
            table: 1
        } : actor.cup ? {
            table: 3,
            couch: 3,
            armchair: 1,
            chat: 3
        } : {
            coffee: 3,
            cooler: 2,
            fridge: 1,
            vending: 1,
            arcade: 1,
            table: 2,
            couch: 3,
            armchair: 1,
            chat: 2
        };
        const options = game.plan().spots.filter(s => s.area === "break" && weights[s.kind] && (!s.pets || pet) && game.free(s, actor));
        if (!options.length) {
            const free = game.nearestFree(page.world.bx + 4 + Math.floor(game.rng() * 4), 11 + Math.floor(game.rng() * 3), actor.key) ?? page.world.entrance.slice();
            const goal = {
                x: free[0],
                y: free[1],
                face: Math.floor(game.rng() * 4),
                offY: 0,
                pose: pet ? "sit" : "stand",
                kind: "floor"
            };
            game.claim(actor, goal);
            return goal;
        }
        let total = 0;
        for (const s of options)
            total += weights[s.kind];
        let r = game.rng() * total;
        let spot = options[options.length - 1];
        for (const s of options) {
            r -= weights[s.kind];
            if (r <= 0) {
                spot = s;
                break;
            }
        }
        game.claim(actor, spot);
        let pose = spot.pose;
        if (spot.kind === "couch" || spot.kind === "armchair")
            pose = pet ? (game.rng() < 0.7 ? "nap" : "sit") : idle && game.rng() < 0.35 ? "nap" : "sit";
        return Object.assign({}, spot, {
            pose: pose
        });
    }

    // Someone stopped listening at a seat: whoever was given the desk there
    // meanwhile waits for it (see seatGoal()), and goes to it now.
    function deskFreed(index) {
        const w = page.world;
        if (!w)
            return;
        const owner = game.actors[Object.keys(w.seatOf).find(id => w.seatOf[id].y * w.cols + w.seatOf[id].x === index)];
        if (owner?.goal?.kind === "wait")
            owner.decide(true);
    }

    // A person sitting at its desk with nothing to do decides, every so often,
    // whether to take a break: each by its own restlessness, and only while
    // the break room has room. Someone whose break is over keeps its place
    // until it is out of the room. A cup brought back from the break room is
    // finished by then.
    function restless(actor) {
        actor.cup = false;
        actor.until = game.now + game.between(game.rng, 15000, 45000);
        if (game.rng() >= actor.restless)
            return;
        let away = 0;
        for (const id of Object.keys(game.actors)) {
            const other = game.actors[id];
            if (other.plan === "break" || other.tx > page.world.xd)
                away++;
        }
        if (away < page.breakRoomCap)
            takeBreak(actor);
    }

    // Sends a person to the break room for a while: a few seconds at a
    // machine, longer at the arcade or sitting down. The stay starts once it
    // gets there.
    function takeBreak(actor) {
        actor.begin(actor.breakTime);
        const goal = actor.goal;
        const stage = goal.pose === "machine";
        actor.stay = stage ? game.between(game.rng, 3000, 5000) : goal.kind === "arcade" ? game.between(game.rng, 8000, 15000) : game.between(game.rng, 10000, 25000);
        if (!stage && goal.kind !== "table" && goal.kind !== "couch" && goal.kind !== "armchair" && goal.kind !== "chat")
            actor.cup = false;
    }

    // ── Talks ───────────────────────────────────────────────────────────────

    // Only what is being said walks a speaker over: not the talks an office
    // already has when it is first seen or caught up with (see catchUp()), nor
    // one still waiting its turn when the topic drops it. A talk can come
    // before one of its two, as a hand-off mostly does before its worker's row:
    // it is heard once both are here, for as long as the topic keeps it. The
    // topic can give a talk its words late ("…" until then): one waiting,
    // walking over or being said takes the ones it has now.
    function hear(talks) {
        const current = {};
        for (const talk of talks) {
            if (talk)
                current[talk.id] = talk;
        }
        for (const actor of Object.values(game.actors)) {
            actor.queue = actor.queue.filter(t => current[t.id]).map(t => current[t.id]);
            const talk = actor.talk;
            const now = talk ? current[talk.id] : undefined;
            if (!now)
                continue;
            actor.reword(now.id, now.text);
        }
        for (const talk of talks) {
            if (!talk || page.seen[talk.id])
                continue;
            if (!page.primed || talk.from === talk.to) {
                page.seen[talk.id] = true;
                continue;
            }
            const from = game.actors[talk.from];
            if (!from || !game.actors[talk.to])
                continue;
            page.seen[talk.id] = true;
            // A speaker keeps at most three talks waiting. When they are full, a
            // talk to someone inside takes the place of the oldest one to
            // someone still outside the door.
            const outside = from.queue.findIndex(t => game.actors[t.to]?.tx < 0);
            if (from.queue.length >= 3 && outside >= 0 && !(game.actors[talk.to].tx < 0))
                from.queue.splice(outside, 1);
            if (from.queue.length < 3)
                from.queue.push(talk);
        }
    }

    function replyOf(actor, kind) {
        if (actor.look.pet)
            return actor.look.species === "cat" ? qsTr("Meow!") : qsTr("Woof!");
        return kind === "delegate" ? qsTr("On it!") : kind === "result" ? qsTr("Thanks!") : qsTr("Sure!");
    }

    // ── The clock ───────────────────────────────────────────────────────────

    // After the people, each tick: the door, the desks, the screens.
    function ticked(dt) {
        letIn();
        hire();
        for (const mover of Object.values(crew.members)) {
            if (stepMover(mover, dt))
                game.stir();
        }
        // By the clock, not by ticks, as a tick is longer while nobody walks.
        if (game.now >= page.screensAt) {
            page.screensAt = game.now + 200;
            updateScreens(game.now - page.screensSeen);
            page.screensSeen = game.now;
        }
        if (page.closeTo && game.ticks % 25 === 0)
            closeRows();
        if (page.jobs.length || page.outside.length)
            game.stir();
    }

    function updateWalking() {
        game.walking = page.jobs.length > 0 || page.outside.length > 0 || everyone().some(a => a.next >= 0 || a.path.length > 0 || a.talk || a.queue.length);
    }

    // What a person shows at its goal where that is not just a Pose's frames.
    function frameAt(actor, goal, time) {
        const F = page.frame;
        switch (goal.pose) {
        case "chat":
            {
                if (actor.cup)
                    return time % 4000 < 700 ? F.sip : F.cup;
                const there = game.actors[game.claims[goal.partner]];
                const talking = there && there.goal?.kind === "chat" && there.tx === there.goal.x && there.ty === there.goal.y;
                return talking && Math.floor((time + (goal.face === 1 ? 900 : 0)) / 1800) % 2 ? F.talk : F.stand;
            }
        case "stand":
            return !actor.cup ? F.stand : time % 4000 < 700 ? F.sip : F.cup;
        case "type":
        case "ask":
        case "board":
        case "arcade":
        case "machine":
        case "book":
        case "nap":
            return null;
        }
        return !actor.cup ? F.sit : time % 4500 < 800 ? F.sitSip : F.sitCup;
    }

    // What a waiting or idle person has on its screen, picked at random
    // every 8 to 20 seconds: a game, a cat video, a meme or some shopping
    // most of the time while waiting, now and then while idle, and otherwise
    // nothing much. Someone asking the user something keeps to the question.
    // A pick holds only for the state it was made in, so a change of state
    // picks again at once.
    function slackOf(actor) {
        const state = actor.person.state;
        if (state !== "waiting" && state !== "idle") {
            actor.slackFor = "";
            return "";
        }
        if (game.now >= actor.slackUntil || actor.slackFor !== state) {
            const odds = state === "waiting" ? 0.75 : 0.35;
            actor.slack = page.screenRng() < odds ? game.pick(page.screenRng, Object.keys(page.slackArt)) : "";
            actor.slackFor = state;
            actor.slackUntil = game.now + game.between(page.screenRng, 8000, 20000);
        }
        return actor.slack;
    }

    // Brings the screens up to date, touching only those whose picture
    // changes, and fills the whiteboards being drawn on by `elapsed` ms: a
    // board takes 12 s to fill whichever clock the page runs on.
    function updateScreens(elapsed) {
        if (!page.world)
            return;
        for (const [k, screen] of page.screens.entries()) {
            const view = screenViews.itemAt(k);
            if (!view)
                continue;
            const seat = page.world.seats[screen.seat];
            // On for whoever sits there, from the step onto the seat.
            const i = seat.y * page.world.cols + seat.x;
            const actor = game.actors[game.claims[i]];
            let mode = "off", slack = "";
            if (actor && actor.goal?.kind === "desk" && (actor.ty * page.world.cols + actor.tx === i || actor.next === i)) {
                const p = actor.person;
                mode = p.state === "failed" ? "failed" : p.state === "working" ? (p.activity ?? "idle") : "idle";
                slack = slackOf(actor);
            }
            const scene = slack ? Math.floor((game.now + actor.beat * 40) / 1000) % page.slackArt[slack].frames.length : view.scene;
            // Only working screens move with the clock.
            const phase = slack || mode === "off" || mode === "idle" || mode === "failed" ? view.phase : Math.floor(game.now / 240);
            if (view.mode === mode && view.slack === slack && view.scene === scene && view.phase === phase)
                continue;
            view.mode = mode;
            view.slack = slack;
            view.scene = scene;
            view.phase = phase;
        }
        for (const [k, board] of page.boards.entries()) {
            const view = boardViews.itemAt(k);
            if (!view)
                continue;
            const drawing = Object.values(game.actors).some(a => a.goal?.board === board.key && a.tx === a.goal.x && a.ty === a.goal.y);
            if (drawing)
                view.progress = Math.min(1, view.progress + Math.max(0, elapsed) / 12000);
        }
    }

    function personState(person) {
        const activity = {
            typing: qsTr("typing"),
            running: qsTr("running commands"),
            testing: qsTr("testing"),
            reading: qsTr("reading"),
            browsing: qsTr("browsing the web"),
            planning: qsTr("planning"),
            delegating: qsTr("delegating"),
            thinking: qsTr("thinking")
        }[person.activity ?? ""] ?? "";
        switch (person.state) {
        case "working":
            return activity ? qsTr("Working, %1").arg(activity) : qsTr("Working");
        case "asking":
            return qsTr("Asking you something");
        case "waiting":
            return qsTr("Waiting on background work");
        case "failed":
            return qsTr("Its last turn failed");
        default:
            return qsTr("Idle");
        }
    }

    // ── The page ────────────────────────────────────────────────────────────

    OfficeArt {
        id: artist

        game: page.game
    }

    // Refits after a resize. A timer rather than Qt.callLater, so that a
    // refit still pending when the page goes away goes with it.
    Timer {
        id: refitLater
        interval: 0
        onTriggered: page.refit()
    }

    // The sky in the windows and the clock follow the time of day.
    Timer {
        property int hour: new Date().getHours()

        interval: 60000
        repeat: true
        running: game.running
        onTriggered: {
            const now = new Date().getHours();
            if (now !== hour) {
                hour = now;
                floor.requestPaint();
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Text {
                objectName: "officeSummary"
                Layout.fillWidth: true
                text: page.summary()
                color: page.muted
                elide: Text.ElideRight
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }

            ShellComboBox {
                visible: page.plugin.environments.length > 1
                outline: true
                implicitWidth: 180
                model: page.plugin.environments.map(environment => page.environmentLabel(environment))
                currentIndex: page.plugin.environments.indexOf(page.environment)
                Accessible.name: qsTr("Machine")
                onActivated: index => page.environment = page.plugin.environments[index]
            }

            ShellButton {
                text: "−"
                toolTip: qsTr("Zoom out")
                enabled: game.pixelScale > game.minScale + 0.001
                onClicked: game.zoomBy(1 / 1.25)
            }

            ShellButton {
                text: qsTr("Fit")
                toolTip: qsTr("Fit the office to the view")
                enabled: game.zoom !== 1
                onClicked: game.zoom = 1
            }

            ShellButton {
                objectName: "officeZoomIn"
                text: "+"
                toolTip: qsTr("Zoom in")
                enabled: game.pixelScale < game.topScale - 0.001
                onClicked: game.zoomBy(1.25)
            }
        }

        World {
            id: game

            objectName: "officeScroller"
            name: qsTr("Office")
            Layout.fillWidth: true
            Layout.fillHeight: true
            seed: 0x0ff1ce
            columns: 0
            rows: 0
            active: page.inSight
            busy: game.actorCount > 0 || page.moves > 0
            tickedAt: Date.now()
            entrance: page.world?.entrance ?? [0, 0]
            onResumed: page.catchUp()
            onTicked: dt => page.ticked(dt)
            onFreed: index => page.deskFreed(index)
            poses: [
                Pose { name: "type"; frames: [page.frame.type2, page.frame.type1]; every: 240 },
                Pose { name: "ask"; frames: [page.frame.raise1, page.frame.stand]; every: [500, 2700] },
                Pose { name: "board"; frames: [page.frame.raise2, page.frame.raise1]; every: 420 },
                Pose { name: "arcade"; frames: [page.frame.type2, page.frame.type1]; every: 260 },
                Pose { name: "machine"; frames: [page.frame.stand] },
                Pose { name: "book"; frames: [page.frame.book] },
                Pose { name: "nap"; frames: [page.frame.nap] }
            ]
            // Hidden until set up; the people in it are out of reach until
            // then too (see their Touchable).
            ready: page.settled
            fontScale: Theme.fontScale
            stageName: "officeStage"
            artName: "officeArt"
            painterName: "officeSheetPainter"
            onSheetPainted: page.settle(page.office)
            // Once for both sides of a resize, at its new size.
            onWidthChanged: refitLater.restart()
            onHeightChanged: refitLater.restart()

            ScrollBar.vertical: ScrollBar {}
            ScrollBar.horizontal: ScrollBar {}

            Canvas {
                id: floor

                objectName: "officeFloor"
                z: -1
                width: Math.max(1, game.pixelWidth)
                height: Math.max(1, game.pixelHeight)
                smooth: false
                antialiasing: false
                onPaint: {
                    page.floorPaints++;
                    artist.paintFloor(getContext("2d"), page.world);
                    page.settle(page.office);
                }
            }

            // Where the break room and the wall before it begin.
            readonly property int breakX: page.world?.bx ?? 0
            readonly property int wallX: breakX - 1

            // The walls, with a doorway to the break room.
            Thing {
                columns: game.columns
                rows: 3
                solid: true
            }
            Thing {
                rows: game.rows
                solid: true
            }
            Thing {
                tx: game.columns - 1
                rows: game.rows
                solid: true
            }
            Thing {
                ty: game.rows - 1
                columns: game.columns
                solid: true
            }
            Thing {
                tx: game.wallX
                rows: 5
                solid: true
            }
            Thing {
                tx: game.wallX
                ty: 7
                rows: game.rows - 7
                solid: true
            }

            // Along the top wall: what stands there, and where to stand at it.
            Repeater {
                model: page.world?.wall ?? []

                delegate: Furniture {
                    id: piece

                    required property var modelData

                    kind: modelData.kind
                    tx: modelData.tx
                    ty: 3
                    columns: modelData.columns
                    height: kind === "shelf" ? 44 : kind === "board" ? 40 : 30
                    solid: true

                    Repeater {
                        model: piece.kind === "plant" ? 0 : piece.columns

                        delegate: Spot {
                            required property int index

                            kind: piece.kind
                            tx: index
                            ty: 1
                            face: kind === "board" ? "up" : "down"
                            pose: kind === "board" ? "board" : "book"
                            extra: kind === "board" ? ({ board: piece.modelData.board, review: piece.modelData.review }) : ({})
                        }
                    }
                }
            }

            // The far corner of the work area; the doorway and the floor around
            // it stay clear so people and movers meeting there can step aside.
            Furniture {
                kind: "plant"
                tx: game.wallX - 1
                ty: game.rows - 2
                height: 30
                solid: true
            }

            // The break room, along its wall.
            Furniture {
                kind: "fridge"
                tx: game.breakX
                ty: 3
                height: 42
                solid: true

                Spot { kind: "fridge"; ty: 1; face: "up"; pose: "machine"; area: "break"; extra: ({ cup: false }) }
            }
            Furniture {
                kind: "counter"
                tx: game.breakX + 1
                ty: 3
                columns: 3
                height: 40
                solid: true

                Spot { kind: "coffee"; ty: 1; face: "up"; pose: "machine"; area: "break"; extra: ({ cup: true }) }
            }
            Furniture {
                kind: "cooler"
                tx: game.breakX + 5
                ty: 3
                height: 34
                solid: true

                Spot { kind: "cooler"; ty: 1; face: "up"; pose: "machine"; area: "break"; extra: ({ cup: true }) }
            }
            Furniture {
                kind: "vending"
                tx: game.breakX + 6
                ty: 3
                columns: 2
                height: 44
                solid: true

                Spot { kind: "vending"; ty: 1; face: "up"; pose: "machine"; area: "break"; extra: ({ cup: false }) }
            }
            Furniture {
                kind: "arcade"
                tx: game.breakX + 8
                ty: 3
                height: 42
                solid: true

                Spot { kind: "arcade"; ty: 1; face: "up"; pose: "arcade"; area: "break"; extra: ({ cup: false }) }
            }
            Furniture {
                kind: "plant"
                tx: game.breakX + 9
                ty: 3
                height: 30
                solid: true
            }

            // The round table and its stools.
            Furniture {
                kind: "table"
                tx: game.breakX + 2
                ty: 8
                columns: 2
                rows: 2
                solid: true
            }
            Furniture {
                kind: "stool"
                tx: game.breakX + 2
                ty: 7
                z: 126

                Spot { kind: "table"; offY: 3; pose: "sit"; area: "break"; seat: true }
            }
            Furniture {
                kind: "stool"
                tx: game.breakX + 3
                ty: 10
                z: 177
                facing: 3

                Spot { kind: "table"; face: "up"; offY: -3; pose: "sit"; area: "break"; seat: true }
            }
            Furniture {
                kind: "stool"
                tx: game.breakX + 1
                ty: 9
                z: 158
                facing: 2

                Spot { kind: "table"; face: "right"; pose: "sit"; area: "break"; seat: true }
            }
            Furniture {
                kind: "stool"
                tx: game.breakX + 4
                ty: 8
                z: 142
                facing: 1

                Spot { kind: "table"; face: "left"; pose: "sit"; area: "break"; seat: true }
            }

            // The couch, its coffee table and an armchair, on a rug.
            Furniture {
                kind: "couch"
                tx: game.breakX + 6
                ty: 7
                columns: 3
                height: 26
                z: 127

                Spot { kind: "couch"; offY: -1; pose: "sit"; area: "break"; seat: true }
                Spot { kind: "couch"; tx: 1; offY: -1; pose: "sit"; area: "break"; seat: true }
                Spot { kind: "couch"; tx: 2; offY: -1; pose: "sit"; area: "break"; seat: true }
            }
            Furniture {
                kind: "coffeeTable"
                tx: game.breakX + 6
                ty: 9
                columns: 2
                solid: true
            }
            Furniture {
                kind: "armchair"
                tx: game.breakX + 9
                ty: 9
                height: 22
                z: 159

                Spot { kind: "armchair"; face: "left"; offY: -1; pose: "sit"; area: "break"; seat: true }
            }

            // A bed for the pets, places to stand and chat, plants.
            Furniture {
                kind: "petBed"
                tx: game.breakX + 8
                ty: 12
                z: 206

                Spot { kind: "petBed"; offY: 1; pose: "nap"; area: "break"; seat: true; extra: ({ pets: true }) }
            }
            Spot {
                kind: "chat"
                tx: game.breakX + 5
                ty: 12
                face: "right"
                pose: "chat"
                area: "break"
                extra: ({ partner: ty * game.columns + tx + 1 })
            }
            Spot {
                kind: "chat"
                tx: game.breakX + 6
                ty: 12
                face: "left"
                pose: "chat"
                area: "break"
                extra: ({ partner: ty * game.columns + tx - 1 })
            }
            Spot {
                kind: "chat"
                tx: game.breakX + 2
                ty: 13
                face: "right"
                pose: "chat"
                area: "break"
                extra: ({ partner: ty * game.columns + tx + 1 })
            }
            Spot {
                kind: "chat"
                tx: game.breakX + 3
                ty: 13
                face: "left"
                pose: "chat"
                area: "break"
                extra: ({ partner: ty * game.columns + tx - 1 })
            }
            Furniture {
                kind: "plant"
                tx: game.breakX
                ty: game.rows - 2
                height: 30
                solid: true
            }
            Furniture {
                kind: "plant"
                tx: game.breakX + 9
                ty: game.rows - 2
                height: 30
                solid: true
            }

            // Each seat's desk and chair, shown while it is in the office. A
            // desk's place is kept while it is out.
            Repeater {
                model: page.world?.seats ?? []

                delegate: Furniture {
                    required property var modelData
                    readonly property bool north: modelData.face === 0

                    kind: north ? "deskN" : "deskS"
                    seed: game.hash("desk" + modelData.index)
                    tx: modelData.x
                    ty: modelData.deskY
                    z: (ty + (north ? 2 : 1)) * 16
                    solid: true
                    visible: page.deskIn(modelData.index)
                }
            }
            Repeater {
                model: page.world?.seats ?? []

                delegate: Furniture {
                    required property var modelData
                    readonly property bool north: modelData.face === 0

                    kind: north ? "chairsN" : "chairsS"
                    seed: game.hash("chair" + modelData.index)
                    tint: modelData.chair
                    tx: modelData.x
                    ty: modelData.y
                    z: (ty + 1) * 16 + (north ? -2 : 1)
                    visible: page.deskIn(modelData.index)

                    Spot { kind: "desk"; seat: true }
                }
            }

            // The screens of the computers facing us.
            Repeater {
                id: screenViews

                model: page.screens

                delegate: Rectangle {
                    id: screen

                    required property var modelData
                    property string mode: "off"
                    property int phase: 0
                    // What its sitter slacks off with, and which frame of it.
                    property string slack: ""
                    property int scene: 0
                    readonly property var art: slack ? page.slackArt[slack] : null
                    readonly property bool slacking: slack !== ""
                    readonly property bool code: mode === "typing" || mode === "thinking" || mode === "delegating" || mode === "planning" || mode === "reading"
                    readonly property bool terminal: mode === "running" || mode === "testing"

                    x: modelData.x
                    y: modelData.y
                    z: modelData.z
                    width: 8
                    height: 6
                    color: art ? art.color : mode === "off" ? "#141a24" : mode === "failed" ? "#7a1f2b" : mode === "browsing" ? "#f2f4f8" : terminal ? "#0d1210" : mode === "idle" ? "#24406a" : "#1d2a44"
                    visible: page.deskIn(modelData.seat)

                    Repeater {
                        model: 3

                        delegate: Rectangle {
                            required property int index

                            visible: screen.mode !== "off" && !screen.art
                            x: screen.mode === "browsing" ? 1 : 1 + (index === 1 ? 1 : 0)
                            y: 1 + index * 2 - (screen.mode === "browsing" && index === 0 ? 1 : 0)
                            height: 1
                            width: {
                                if (screen.mode === "failed")
                                    return index === 1 ? 6 : 0;
                                if (screen.mode === "browsing")
                                    return index === 0 ? 8 : 2 + ((screen.phase + index * 3) % 4);
                                if (screen.mode === "idle")
                                    return index === 1 ? 2 : 0;
                                return 1 + ((screen.phase * (index + 2) + index * 5) % 6);
                            }
                            color: {
                                if (screen.mode === "failed")
                                    return "#ffb3b3";
                                if (screen.mode === "browsing")
                                    return index === 0 ? "#4a90d9" : "#9aa5b0";
                                if (screen.mode === "testing")
                                    return (screen.phase + index) % 5 === 0 ? "#ff6b6b" : "#5fd38a";
                                if (screen.mode === "running")
                                    return "#5fd38a";
                                if (screen.mode === "idle")
                                    return "#9cc8ff";
                                return ["#c792ea", "#82aaff", "#f8c25c"][index];
                            }
                        }
                    }

                    // Its slacking frame: up to six blocks of pixels,
                    // made while it slacks and only moved as frames change.
                    Repeater {
                        model: screen.slacking ? 6 : 0

                        delegate: Rectangle {
                            required property int index
                            readonly property var block: screen.art ? screen.art.frames[screen.scene % screen.art.frames.length][index] : undefined

                            visible: block !== undefined
                            x: block?.[0] ?? 0
                            y: block?.[1] ?? 0
                            width: block?.[2] ?? 0
                            height: block?.[3] ?? 0
                            color: block?.[4] ?? "transparent"
                        }
                    }
                }
            }

            // The project on each desk, for whoever has it.
            Repeater {
                id: markViews

                model: page.deskMarks

                delegate: Item {
                    id: mark

                    required property var modelData
                    readonly property var shows: page.signAt(modelData.seat)
                    // The last it showed, so a desk that empties is not painted again.
                    property var last: null
                    readonly property string kind: last?.kind ?? ""
                    readonly property string label: last?.label ?? ""
                    readonly property string tint: last?.tint ?? ""
                    readonly property string emoji: last?.emoji ?? ""
                    readonly property string url: last?.url ?? ""
                    readonly property string sign: [kind, label, tint, emoji].join("\n")

                    objectName: "officeDeskMark"
                    x: modelData.x
                    y: modelData.y
                    z: modelData.z
                    width: modelData.w
                    height: modelData.h
                    visible: !!shows?.kind && page.deskIn(modelData.seat)
                    onShowsChanged: if (shows) last = shows
                    Component.onCompleted: if (shows) last = shows
                    onSignChanged: tile.requestPaint()

                    Canvas {
                        id: tile

                        anchors.fill: parent
                        smooth: false
                        antialiasing: false
                        onPaint: {
                            page.markPaints++;
                            page.paintMark(getContext("2d"), mark);
                        }
                    }
                    // An emoji, drawn at the mark's own few pixels.
                    Item {
                        anchors.fill: parent
                        visible: mark.kind === "emoji"
                        layer.enabled: visible
                        layer.smooth: false
                        layer.textureSize: Qt.size(width, height)

                        Text {
                            anchors.centerIn: parent
                            text: mark.emoji
                            font.pixelSize: mark.height
                            Accessible.ignored: true
                        }
                    }
                    // A logo, drawn at the mark's own few pixels.
                    Image {
                        objectName: "officeDeskLogo"
                        Accessible.ignored: true
                        x: Math.floor((mark.width - mark.height) / 2)
                        width: mark.height
                        height: mark.height
                        visible: mark.kind === "image" && status === Image.Ready
                        source: mark.kind === "image" ? mark.url : ""
                        sourceSize: Qt.size(mark.height, mark.height)
                        fillMode: Image.PreserveAspectFit
                        smooth: false
                        asynchronous: true
                    }
                }
            }

            // What has been drawn on each whiteboard.
            Repeater {
                id: boardViews

                model: page.boards

                delegate: Item {
                    id: board

                    required property var modelData
                    readonly property real blank: 0.15
                    property real progress: blank
                    // Doodles, or on the review corner's board a
                    // checklist beside a diff.
                    readonly property var marks: modelData.review ? [[1, 1, 3, 3, "#3d4451"], [2, 2, 1, 1, "#3fa560"], [6, 2, 12, 1, "#3d4451"], [1, 7, 3, 3, "#3d4451"], [2, 8, 1, 1, "#3fa560"], [6, 8, 9, 1, "#3d4451"], [1, 13, 3, 3, "#3d4451"], [6, 14, 11, 1, "#3d4451"], [22, 2, 12, 1, "#3fa560"], [22, 5, 9, 1, "#e05d5d"], [22, 8, 13, 1, "#3fa560"], [22, 11, 7, 1, "#3fa560"], [22, 14, 10, 1, "#e05d5d"]] : [[1, 1, 14, 1, "#3d4451"], [1, 4, 10, 1, "#4a90d9"], [1, 7, 12, 1, "#4a90d9"], [19, 1, 8, 7, "#e05d5d"], [30, 3, 6, 1, "#3d4451"], [1, 11, 6, 5, "#5fbf7a"], [9, 12, 18, 1, "#3d4451"], [9, 15, 12, 1, "#3d4451"], [29, 10, 7, 6, "#e8894a"]]

                    x: modelData.x
                    y: modelData.y
                    z: modelData.z
                    width: 38
                    height: 18

                    Repeater {
                        model: board.marks

                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            readonly property int count: board.marks.length
                            readonly property real start: index / count

                            x: modelData[0]
                            y: modelData[1]
                            height: modelData[3] > 1 && modelData[2] > 1 ? modelData[3] : 1
                            width: Math.round(modelData[2] * Math.max(0, Math.min(1, (board.progress - start) * count)))
                            color: modelData[3] > 1 && modelData[2] > 1 ? "transparent" : modelData[4]
                            border.width: modelData[3] > 1 && modelData[2] > 1 ? 1 : 0
                            border.color: modelData[4]
                            visible: width > 0
                        }
                    }
                }
            }

            // The movers, and the desks they carry.
            Crowd {
                id: crew

                Actor {
                    id: mover

                    property int job: -1
                    property bool carrying: false
                    property string chair: "#3d4a63"
                    property var look: null

                    objectName: "officeMover:" + key
                    manual: true
                    height: 24
                    // Over the furniture on its row, under the people.
                    z: py + 16.0005
                    walkFrames: [1, 0, 2, 0]
                    Component.onCompleted: {
                        job = entry.job;
                        carrying = entry.carrying;
                        chair = entry.chair;
                        look = page.moverLook(key);
                        // Its turn at the seeded stream, as each person takes one.
                        game.rng();
                    }

                    Item {
                        width: 16
                        height: 24
                        clip: true

                        Art {
                            x: -(mover.frame + (mover.carrying ? 3 : 0)) * 18
                            y: -mover.dir * 26
                            width: 108
                            height: 104
                            key: mover.look
                            draw: ctx => {
                                if (mover.look)
                                    artist.paintMoverSheet(ctx, mover.look);
                            }
                        }
                    }
                    Art {
                        objectName: "officeLoad:" + mover.key
                        visible: mover.carrying
                        // Seen from behind, the mover's back hides it.
                        z: mover.dir === 3 ? -1 : 0
                        y: 8
                        width: 16
                        height: 14
                        key: mover.chair
                        draw: ctx => artist.paintLoad(ctx, mover.chair)
                    }
                }
            }

            // The people, and what each does by its thread's state.
            Crowd {
                id: staff

                Actor {
                    id: who

                    property var person: entry
                    // Both its own for as long as it is in: who it looks like,
                    // and the chance it gets up for a break each time it
                    // thinks of one (see restless()).
                    property var look: null
                    property real restless: 0
                    property bool cup: false
                    property string icon: ""
                    // What it slacks off with on its screen, the state it
                    // picked it in, and until when (see slackOf()); `beat`
                    // keeps its frames out of step with others'.
                    property string slack: ""
                    property string slackFor: ""
                    property real slackUntil: 0
                    readonly property int beat: game.hash(key) % 25
                    readonly property string headIcon: goal?.pose === "nap" && tx === goal.x && ty === goal.y ? "nap" : icon
                    readonly property alias breakTime: breakTime

                    height: 24
                    // Over the furniture and movers on its row.
                    z: py + 16.001
                    headY: artist.seated(frame) ? 2 : 0
                    bubbleName: "officeBubble:" + key
                    walkFrames: [page.frame.walk1, page.frame.stand, page.frame.walk2, page.frame.stand]
                    standFrame: page.frame.stand
                    sitFrame: page.frame.sit
                    talkFrame: page.frame.talk
                    frameFor: (goal, time) => page.frameAt(who, goal, time)
                    reply: talk => page.replyOf(who, talk.kind)
                    Component.onCompleted: {
                        look = artist.lookFor(entry);
                        restless = game.between(game.rng, 0.15, 0.5);
                    }

                    activities: [
                        Activity {
                            name: "asking"
                            when: who.person?.state === "asking"
                            goal: actor => page.seatGoal(actor, "ask")
                            onChosen: {
                                who.cup = false;
                                who.icon = "ask";
                            }
                        },
                        Activity {
                            name: "failed"
                            when: who.person?.state === "failed"
                            goal: actor => page.seatGoal(actor, "sit")
                            onChosen: {
                                who.cup = false;
                                who.icon = "fail";
                            }
                        },
                        Activity {
                            readonly property string kindOfWork: who.person?.activity ?? ""
                            // A planner whose kind changes goes to its own kind's whiteboard.
                            name: "working:" + kindOfWork + (kindOfWork === "planning" ? ":" + (who.person?.kind ?? "") : "")
                            when: who.person?.state === "working"
                            goal: actor => page.workGoal(actor)
                            onChosen: {
                                who.cup = false;
                                who.icon = kindOfWork === "thinking" || kindOfWork === "delegating" ? "think" : "";
                            }
                        },
                        // Waiting and idle people sit at their desks, and now
                        // and then get up for a short break, counting from
                        // when they sit down.
                        Activity {
                            name: "rest"
                            keep: ["break"]
                            goal: actor => page.seatGoal(actor, "sit")
                            stay: [15000, 45000]
                            mustSit: true
                            onChosen: who.icon = ""
                            onEnded: page.restless(who)
                        },
                        // Begun by takeBreak(), never by itself.
                        Activity {
                            id: breakTime

                            name: "break"
                            when: false
                            mustArrive: false
                            goal: actor => page.breakGoal(actor, actor.person.state === "idle")
                            // With a cup from the machine it sits down with it
                            // in the break room, or takes it back to its desk.
                            onEnded: {
                                if (who.goal?.pose !== "machine" || !who.goal.cup)
                                    return;
                                who.cup = true;
                                if (game.rng() < 0.5)
                                    page.takeBreak(who);
                            }
                        }
                    ]

                    Sheet {
                        columns: 15
                        rows: 3
                        cellHeight: 24
                        frame: who.frame
                        facing: who.dir
                        // A row each facing us, left and away.
                        draw: (f, row) => artist.personCell(who.look, f, [0, 1, 3][row])
                    }
                    // Tab walks the people; a focused one shows its card as a
                    // hovered one does, and Return or Space opens its thread.
                    // Nobody is reachable while the office is being set up:
                    // hidden, not disabled, as a MouseArea's enabled leaves
                    // Tab, keys and screen readers in.
                    Touchable {
                        objectName: "officePerson:" + who.key
                        name: who.person?.title ?? qsTr("Person")
                        visible: page.settled
                        x: 2
                        y: 2
                        width: 12
                        height: 21
                        onActivated: page.openPerson(who.key)
                        onEntered: page.hovered = who.key
                        onExited: {
                            if (page.hovered === who.key && !activeFocus)
                                page.hovered = "";
                        }
                        onActiveFocusChanged: {
                            if (activeFocus)
                                page.hovered = who.key;
                            else if (page.hovered === who.key && !containsMouse)
                                page.hovered = "";
                        }
                    }

                    // Over its head, where the bubble is while it has none.
                    overhead: Item {
                        objectName: "officeIcon:" + who.key
                        visible: !who.bubble && who.headIcon !== ""
                        x: -5 * game.pixelScale
                        y: (-11 - game.bob) * game.pixelScale
                        width: 10 * game.drawScale
                        height: 11 * game.drawScale
                        scale: game.pixelScale / game.drawScale
                        transformOrigin: Item.TopLeft
                        layer.enabled: visible && game.resampled
                        layer.smooth: true

                        Item {
                            width: 10
                            height: 11
                            scale: game.drawScale
                            transformOrigin: Item.TopLeft
                            clip: true

                            Art {
                                x: -({ ask: 0, fail: 16, think: 32, nap: 48 }[who.headIcon] ?? 0)
                                width: 64
                                height: 11
                                draw: ctx => artist.paintIcons(ctx)
                            }
                        }
                    }
                }
            }

            // Who the hovered person is, over everyone's bubbles.
            overlay: Rectangle {
                id: card

                // game.actors changes in place: its count says when.
                readonly property var actor: game.actorCount && page.hovered ? game.actors[page.hovered] ?? null : null
                readonly property var person: page.people.find(p => p.id === page.hovered) ?? null
                // The part of the stage in view, in the overlay's coordinates.
                readonly property real viewX: game.contentX - game.overlayItem.parent.x
                readonly property real viewY: game.contentY - game.overlayItem.parent.y

                objectName: "officeCard"
                visible: person !== null && actor !== null
                z: 10
                x: actor ? Math.max(viewX, Math.min(viewX + game.width - width, (actor.x + 8) * game.pixelScale + 10 * game.pixelScale)) : 0
                y: actor ? Math.max(viewY, Math.min(viewY + game.height - height, (actor.y + actor.headY) * game.pixelScale - 4 * game.pixelScale)) : 0
                width: Math.min(280, Math.max(160, cardColumn.implicitWidth + 20))
                height: cardColumn.implicitHeight + 16
                color: "#211d2a"
                border.color: "#fbf8f1"
                border.width: 2

                Column {
                    id: cardColumn

                    x: 10
                    y: 8
                    width: card.width - 20
                    spacing: 2

                    Text {
                        objectName: "officeCardTitle"
                        width: parent.width
                        text: card.person?.title ?? ""
                        textFormat: Text.PlainText
                        color: "#fbf8f1"
                        elide: Text.ElideRight
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                        font.weight: Font.DemiBold
                    }

                    Row {
                        width: parent.width
                        spacing: 5
                        visible: projectText.text.length > 0

                        ProjectIcon {
                            objectName: "officeCardProjectIcon"
                            anchors.verticalCenter: parent.verticalCenter
                            size: Math.round(12 * Theme.fontScale)
                            icon: card.person ? page.projectIcons?.[page.environment + ":" + card.person.projectId] ?? null : null
                            name: card.person?.project ?? ""
                        }

                        Text {
                            id: projectText

                            objectName: "officeCardProject"
                            width: parent.width - parent.spacing - Math.round(12 * Theme.fontScale)
                            text: [card.person?.project ?? "", card.person?.kind === "reviewer" ? qsTr("reviewing") : "", card.actor?.look.pet ? card.actor.look.breed : ""].filter(s => s).join(" · ")
                            textFormat: Text.PlainText
                            color: "#bdb6c9"
                            elide: Text.ElideRight
                            font.pixelSize: Math.round(11 * Theme.fontScale)
                        }
                    }

                    Text {
                        objectName: "officeCardAgent"
                        width: parent.width
                        visible: text.length > 0
                        text: [card.person?.provider ?? "", card.person?.model ?? ""].filter(s => s).join(" · ")
                        textFormat: Text.PlainText
                        color: "#bdb6c9"
                        elide: Text.ElideRight
                        font.pixelSize: Math.round(11 * Theme.fontScale)
                    }

                    Text {
                        objectName: "officeCardState"
                        width: parent.width
                        text: card.person ? page.personState(card.person) : ""
                        textFormat: Text.PlainText
                        color: card.person?.state === "asking" ? "#ffd84a" : card.person?.state === "failed" ? "#ff8a8a" : "#9fe0b0"
                        elide: Text.ElideRight
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }
                }
            }
        }
    }
    // Over the stage, which is hidden until set up, in the middle of the view
    // at any zoom.
    Text {
        parent: game
        objectName: "officeMessage"
        anchors.centerIn: parent
        width: Math.min(parent.width - 32, 420)
        visible: text.length > 0
        text: {
            if (page.plugin.environments.length === 0)
                return qsTr("No machine runs the Office plugin yet.");
            if (page.office === null)
                return qsTr("Waiting for the office…");
            if (page.people.length === 0)
                return qsTr("Nobody is in the office. Threads show up here as they work.");
            return page.settled ? "" : qsTr("Setting up the office…");
        }
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        color: page.muted
        font.pixelSize: Math.round(13 * Theme.fontScale)
    }

    function summary() {
        if (page.office === null)
            return qsTr("Waiting for the office…");
        const count = state => page.people.filter(p => p.state === state).length;
        const parts = [];
        if (count("working"))
            parts.push(qsTr("%1 working").arg(count("working")));
        if (count("asking"))
            parts.push(qsTr("%1 asking").arg(count("asking")));
        if (count("waiting"))
            parts.push(qsTr("%1 waiting").arg(count("waiting")));
        if (count("idle"))
            parts.push(qsTr("%1 idle").arg(count("idle")));
        if (count("failed"))
            parts.push(qsTr("%1 failed").arg(count("failed")));
        return parts.length ? parts.join(" · ") : qsTr("Nobody in");
    }
}
