pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The Office page: a machine's threads as people in a pixel-art office. Each
// thread sits at a desk with the workers it delegated to in the same group of
// desks; some workers are cats and dogs. What a person does follows its agent:
// typing, running and testing at the computer, planning at a whiteboard, reading
// at a bookshelf, and waiting or idling in the break room. A talk in the
// `office` topic walks the speaker up to the other person with a speech bubble.
// Hover a person for who it is; click it to open its thread.
//
// Everything is drawn once into canvases (the floor, each piece of furniture,
// and a sprite sheet per person) and animated by moving them on one timer that
// runs only while the page is shown. The sprite sheets are painted a few a
// frame; until the floor and everyone on it are drawn, the page says the office
// is being set up.
Item {
    id: page

    property var plugin
    // environment → the last value of its `office` topic.
    property var byEnvironment: ({})
    // environment → its watch.
    property var watches: ({})
    property string environment: ""
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

    property bool applicationActive: Qt.application.state === Qt.ApplicationActive
    property int actorCount: 0
    // Movers at work and desks waiting for one.
    property int moves: 0
    readonly property bool animating: visible && applicationActive && (actorCount > 0 || moves > 0)
    property bool walking: false
    // The office fits the view at zoom 1, by its width or its height,
    // whichever runs out first; each zoom button is a quarter more or less.
    // It can shrink below one device pixel per art pixel only to fit, and
    // grows no further than topScale, the most zoomed in scale.
    property real zoom: 1
    readonly property real devicePixelRatio: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
    readonly property real fitScale: worldCols > 0 && worldRows > 0 ? Math.max(0.01, Math.min((scroller.width - 8) / (worldCols * 16), (scroller.height - 8) / (worldRows * 16))) : 1
    readonly property real minScale: Math.min(1, fitScale)
    readonly property real maxScale: 8
    readonly property real pixelScale: zoom === 1 ? Math.max(minScale, Math.min(topScale, fitScale)) : snapScale(fitScale * zoom)
    // Nearest-neighbour art at a fractional scale draws some art pixels a
    // device pixel wider than others. So the art is drawn at the next whole
    // number of device pixels per art pixel, drawScale, into a layer shrunk
    // smoothly to pixelScale. From `crispFrom` device pixels per art pixel up
    // a step of one device pixel is under a quarter, so a zoomed scale snaps
    // to whole device pixels and is drawn directly; the layer is then at most
    // `crispFrom` times the office's art size, or about the view's size at Fit.
    readonly property int crispFrom: 4
    readonly property real drawScale: Math.ceil(pixelScale * devicePixelRatio - 0.001) / devicePixelRatio
    readonly property bool resampled: drawScale - pixelScale > 0.001

    // The scale shown for a wanted zoomed scale: kept within bounds, and
    // rounded to whole device pixels where that is fine enough, never past
    // the largest whole number of device pixels within maxScale.
    function snapScale(wanted) {
        const ratio = devicePixelRatio;
        const scale = Math.max(minScale, Math.min(maxScale, wanted));
        const devicePixels = scale * ratio;
        return devicePixels >= crispFrom ? Math.min(Math.round(devicePixels), Math.floor(maxScale * ratio + 0.001)) / ratio : scale;
    }
    // The most zoomed in scale shown.
    readonly property real topScale: snapScale(maxScale)

    // Zooms from the scale shown, so a step always moves it; where the scale
    // snaps, by at least one device pixel, so in and out take the same path.
    function zoomBy(factor) {
        const ratio = devicePixelRatio;
        let next = pixelScale * factor;
        if (next * ratio >= crispFrom) {
            // A scale between whole device pixels (Fit) moves to the next
            // whole one, a whole one by at least one device pixel.
            const now = factor > 1 ? Math.floor(pixelScale * ratio + 0.001) : Math.ceil(pixelScale * ratio - 0.001);
            const step = Math.round(next * ratio);
            next = (factor > 1 ? Math.max(step, now + 1) : Math.min(step, now - 1)) / ratio;
        }
        zoom = Math.max(minScale, Math.min(maxScale, next)) / fitScale;
    }

    // The office as drawn: its size in tiles, its furniture, each desk and
    // chair, the screens of its computers and its whiteboards. Built once; the
    // movers bring desks in and take them out.
    property int worldCols: 0
    property int worldRows: 0
    property var props: []
    property var units: []
    property var screens: []
    property var boards: []
    property var deskMarks: []
    property int deskCount: 0
    // How many times the floor, and the desks' project marks, have been
    // painted.
    property int floorPaints: 0
    property int markPaints: 0
    // The sidebar's project icons; a desk shows its sitter's.
    readonly property var projectIcons: Shell.state.projectIcons ?? null
    property string hovered: ""

    // The simulation, mutated in place each tick; nothing binds to these.
    property var world: null
    property var actors: ({})
    property var views: ({})
    property var overlays: ({})
    property var screenViews: ({})
    property var unitViews: ({})
    property var markViews: ({})
    property var moverViews: ({})
    property var boardViews: ({})
    property var occupied: []
    property var claims: ({})
    property var movers: ({})
    property var jobs: []
    // People who came in while the doorway was busy wait outside, in order.
    property var outside: []
    property int moversHired: 0
    property var seen: ({})
    property var arrival: ({})
    property int arrivals: 0
    property bool primed: false
    property real now: 0
    property int ticks: 0
    property var rng: random(0x0ff1ce)

    // The people whose sprite sheets wait to be painted, in order. A full
    // office's sheets painted at once block the page for a tenth of a second
    // on Qt and for seconds on Ljós, so paintSheets() paints as many each
    // frame as fit sheetBudget milliseconds, by what the last ones took.
    property var sheetQueue: []
    property int sheetsPending: 0
    property real sheetCost: 0
    readonly property real sheetBudget: 10
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
    onOfficeChanged: take(office)
    onProjectIconsChanged: updateMarks()
    Component.onCompleted: follow()

    Connections {
        target: page.plugin

        function onEnvironmentsChanged() {
            page.follow();
        }
    }

    // ── Randomness that is the same every time ──────────────────────────────

    function hash(text) {
        let h = 2166136261;
        for (let i = 0; i < text.length; i++) {
            h ^= text.charCodeAt(i);
            h = Math.imul(h, 16777619);
        }
        return h >>> 0;
    }

    function random(seed) {
        let s = seed >>> 0;
        return () => {
            s = (s + 0x6D2B79F5) >>> 0;
            let t = s;
            t = Math.imul(t ^ (t >>> 15), t | 1);
            t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
            return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
        };
    }

    function pick(r, list) {
        return list[Math.floor(r() * list.length)];
    }

    function between(r, low, high) {
        return low + r() * (high - low);
    }

    function shade(hex, k) {
        const n = parseInt(hex.slice(1), 16);
        let c = [n >> 16, (n >> 8) & 255, n & 255];
        c = c.map(v => k < 0 ? v * (1 + k) : v + (255 - v) * k);
        return "#" + c.map(v => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, "0")).join("");
    }

    // ── Looks ───────────────────────────────────────────────────────────────

    readonly property var skins: ["#ffe1c9", "#f7cfab", "#ebb98f", "#d9a273", "#c08657", "#a06a43", "#7d4e30", "#5a3823"]
    readonly property var hairs: ["#2a1c15", "#3f2a1d", "#5e3b24", "#80522f", "#a8743f", "#d8b06a", "#ecd59a", "#9c3b22", "#1c1c22", "#8b8b92", "#dedad2"]
    readonly property var funHairs: ["#e35d9d", "#5b8ff9", "#4fbf85", "#9b6cf0", "#f08a3c", "#3fc1c9"]
    readonly property var cloth: ["#e05d5d", "#e8894a", "#e8c14a", "#7cc06a", "#3fa58f", "#4a90d9", "#5a6fd6", "#8e62c9", "#d36ba6", "#3d4451", "#ece8de", "#6d7a8a", "#a0522d", "#2f6f5e", "#c0392b", "#264653"]
    readonly property var pantsColors: ["#2e3542", "#3b4a6b", "#4b3b2f", "#5a5f6b", "#1f2229", "#6b5a45", "#334d6e", "#2c2c34", "#7a6a55"]
    readonly property var shoeColors: ["#1f1b1b", "#4a2e1e", "#efefef", "#7a3b2a", "#2e3a5c"]
    readonly property var cats: [
        {
            breed: "orange tabby",
            base: "#e8913a",
            dark: "#b55f1d",
            light: "#f7cf98",
            eye: "#7bc043",
            stripes: true,
            chest: true
        },
        {
            breed: "grey tabby",
            base: "#8d909b",
            dark: "#5b5e69",
            light: "#c9cbd1",
            eye: "#c9d94a",
            stripes: true,
            chest: true
        },
        {
            breed: "black cat",
            base: "#2f2c36",
            dark: "#1b1a20",
            light: "#4a4653",
            eye: "#f2c94c"
        },
        {
            breed: "white cat",
            base: "#f3f0ea",
            dark: "#cdc6bb",
            light: "#ffffff",
            eye: "#5aa9e6"
        },
        {
            breed: "calico",
            base: "#f4efe6",
            dark: "#cfc6b8",
            light: "#ffffff",
            eye: "#7bc043",
            patches: ["#e0893a", "#3b3638"]
        },
        {
            breed: "siamese",
            base: "#efe2c8",
            dark: "#cdbb98",
            light: "#f9f1e2",
            eye: "#5aa9e6",
            points: "#5a4033"
        },
        {
            breed: "tuxedo",
            base: "#28262d",
            dark: "#161519",
            light: "#f4f2ee",
            eye: "#9bd35a",
            chest: true,
            muzzle: true
        }
    ]
    readonly property var dogs: [
        {
            breed: "golden retriever",
            base: "#e0a85a",
            dark: "#b07a35",
            light: "#f3d39c",
            ears: "floppy",
            chest: true
        },
        {
            breed: "chocolate lab",
            base: "#6b3f26",
            dark: "#4a2a19",
            light: "#8c5a3b",
            ears: "floppy"
        },
        {
            breed: "black lab",
            base: "#2b2727",
            dark: "#171515",
            light: "#433d3d",
            ears: "floppy"
        },
        {
            breed: "dalmatian",
            base: "#f6f4f0",
            dark: "#2b2727",
            light: "#ffffff",
            ears: "floppy",
            spots: true,
            earColor: "#2b2727"
        },
        {
            breed: "corgi",
            base: "#e39a4b",
            dark: "#b06e2c",
            light: "#fbf3e8",
            ears: "up",
            chest: true,
            muzzle: true,
            short: true
        },
        {
            breed: "husky",
            base: "#7c8494",
            dark: "#4f5562",
            light: "#f4f4f6",
            ears: "up",
            mask: true,
            eye: "#6cc4f0",
            chest: true
        },
        {
            breed: "beagle",
            base: "#c98a4b",
            dark: "#8a5a2c",
            light: "#fbf5ec",
            ears: "floppy",
            saddle: "#2f2a28",
            chest: true,
            muzzle: true
        },
        {
            breed: "pug",
            base: "#dcc093",
            dark: "#3a3030",
            light: "#ecd9b6",
            ears: "floppy",
            face: "#3a3030",
            curly: true,
            earColor: "#3a3030"
        }
    ]

    // A person's look, from its thread id alone, so it is the same every time.
    // About a third of the workers are pets.
    function lookFor(person) {
        const r = random(hash(person.id));
        if (person.parentId && r() < 0.34) {
            const cat = r() < 0.5;
            const breed = pick(r, cat ? page.cats : page.dogs);
            return Object.assign({
                pet: true,
                species: cat ? "cat" : "dog",
                gender: "",
                collar: pick(r, ["#e04848", "#3b82f6", "#22a06b", "#e8b928", "#a855f7"]),
                eye: cat ? "#7bc043" : "#2a2226"
            }, breed);
        }
        const woman = r() < 0.5;
        const style = woman ? pick(r, ["long", "long", "bob", "ponytail", "bun", "pigtails", "pixie", "bob", "curly", "long"]) : pick(r, ["short", "short", "sidepart", "spiky", "buzz", "bald", "curly", "mohawk", "long", "sidepart"]);
        const look = {
            pet: false,
            species: "human",
            gender: woman ? "woman" : "man",
            skin: pick(r, page.skins),
            hair: r() < 0.15 ? pick(r, page.funHairs) : pick(r, page.hairs),
            style: style,
            top: woman && r() < 0.3 ? "dress" : pick(r, ["tee", "tee", "collared", "tie", "hoodie", "sweater", "blazer"]),
            shirt: pick(r, page.cloth),
            accent: pick(r, page.cloth),
            pants: pick(r, page.pantsColors),
            shoes: pick(r, page.shoeColors),
            glasses: r() < 0.3,
            headphones: r() < 0.14,
            hat: r() < 0.12 ? pick(r, ["beanie", "cap"]) : "",
            beard: !woman && r() < 0.32 ? pick(r, ["beard", "moustache", "stubble"]) : "",
            earrings: woman && r() < 0.4,
            lashes: woman && r() < 0.65,
            lipstick: woman && r() < 0.35,
            bow: woman && r() < 0.15,
            lanyard: r() < 0.2,
            blush: r() < 0.5
        };
        if (look.accent === look.shirt)
            look.accent = page.cloth[(page.cloth.indexOf(look.shirt) + 5) % page.cloth.length];
        if (look.hat)
            look.bow = false;
        if (look.headphones)
            look.hat = "";
        return look;
    }

    // ── Sprites ─────────────────────────────────────────────────────────────
    //
    // A sprite sheet is 15 frames across (16 px each) and 4 directions down
    // (24 px each): down, left, right (left mirrored) and up. A frame is built
    // as three lists of rectangles: under (the shadow), main (drawn with a
    // one-pixel outline around the whole silhouette) and over (details).

    readonly property string outline: "#211d2a"

    function seated(f) {
        return f === 3 || f === 4 || f === 5 || f === 8 || f === 9 || f === 14;
    }

    function humanFrame(L, f, d) {
        const U = [], M = [], O = [];
        const S = seated(f);
        const dy = S ? 2 : 0;
        const hy = 2 + dy + (f === 14 ? 1 : 0);
        const side = d === 1, back = d === 3;
        const skin = L.skin, skinDark = shade(L.skin, -0.2);
        const top = L.top;
        const white = "#f2efe8";
        const body = top === "tie" ? white : L.shirt;
        const sleeve = top === "tie" ? white : L.shirt;
        const sleeveShade = shade(sleeve, -0.14);
        const short = top === "tee" || top === "dress";
        const hair = L.hair, hairDark = shade(L.hair, -0.25);
        const legColor = top === "dress" ? skin : L.pants;
        const m = (x, y, w, h, c) => M.push([x, y, w, h, c]);
        const o = (x, y, w, h, c) => O.push([x, y, w, h, c]);
        const arm = (x, y, len) => {
            if (short) {
                m(x, y, 2, 2, sleeveShade);
                if (len > 2)
                    m(x, y + 2, 2, len - 2, skin);
            } else {
                m(x, y, 2, len, sleeveShade);
            }
        };
        const sideArm = (x, y, w, h) => {
            if (short) {
                m(x, y, w, Math.min(2, h), sleeveShade);
                if (h > 2)
                    m(x, y + 2, w, h - 2, skin);
            } else {
                m(x, y, w, h, sleeveShade);
            }
        };

        U.push([3, 21, 10, 2, "rgba(0,0,0,0.28)"]);

        // Legs and shoes.
        if (!S) {
            if (!side) {
                const l1 = f === 1 ? 2 : 3, l2 = f === 2 ? 2 : 3;
                m(5, 17, 3, l1, legColor);
                m(8, 17, 3, l2, shade(legColor, -0.08));
                m(5, 17 + l1, 3, 1, L.shoes);
                m(8, 17 + l2, 3, 1, L.shoes);
            } else if (f === 1) {
                m(8, 17, 3, 3, shade(legColor, -0.15));
                m(4, 17, 3, 3, legColor);
                m(3, 20, 4, 1, L.shoes);
                m(8, 20, 4, 1, shade(L.shoes, -0.1));
            } else if (f === 2) {
                m(7, 17, 3, 3, shade(legColor, -0.15));
                m(5, 17, 3, 3, legColor);
                m(4, 20, 4, 1, L.shoes);
                m(7, 20, 3, 1, shade(L.shoes, -0.1));
            } else {
                m(6, 17, 4, 3, legColor);
                m(5, 20, 5, 1, L.shoes);
            }
        } else if (side) {
            m(3, 17, 7, 2, L.pants === legColor ? legColor : shade(L.shirt, -0.1));
            m(3, 19, 2, 1, legColor);
            m(2, 20, 3, 1, L.shoes);
        } else if (back) {
            m(5, 18, 6, 2, top === "dress" ? L.shirt : legColor);
        } else {
            m(5, 18, 6, 2, top === "dress" ? L.shirt : L.pants);
            m(5, 20, 2, 1, L.shoes);
            m(9, 20, 2, 1, L.shoes);
        }

        // Body.
        if (side)
            m(6, 11 + dy, 5, 6, body);
        else
            m(5, 11 + dy, 6, 6, body);
        if (top === "dress" && !S)
            m(side ? 5 : 4, 15, side ? 7 : 8, 3, L.shirt);

        // Arms and what the hands hold. A mover holds a desk in front of it
        // (see paintLoad()).
        if (L.carry && !side) {
            arm(3, 11, 5);
            arm(11, 11, 5);
        } else if (L.carry) {
            sideArm(7, 11, 3, 3);
            m(4, 13, 4, 2, short ? skin : sleeveShade);
        } else if (!side) {
            const right = f === 6 || f === 7 || f === 8 || f === 9 || f === 10 || f === 11;
            const left = f === 13;
            if (f === 4 || f === 5) {
                arm(3, 13, 3);
                arm(11, 13, 3);
                if (back) {
                    m(3, f === 4 ? 12 : 13, 2, 1, skin);
                    m(11, f === 4 ? 13 : 12, 2, 1, skin);
                } else {
                    m(4, f === 4 ? 16 : 15, 2, 1, skin);
                    m(10, f === 4 ? 15 : 16, 2, 1, skin);
                }
            } else if (f === 12) {
                arm(3, 11 + dy, 3);
                arm(11, 11 + dy, 3);
                if (!back) {
                    m(4, 13 + dy, 8, 4, L.accent);
                    o(5, 13 + dy, 2, 3, "#f6eedc");
                    o(9, 13 + dy, 2, 3, "#f6eedc");
                    m(3, 14 + dy, 2, 2, skin);
                    m(11, 14 + dy, 2, 2, skin);
                } else {
                    m(4, 14 + dy, 2, 1, skin);
                    m(10, 14 + dy, 2, 1, skin);
                }
            } else {
                if (!left) {
                    const swing = f === 2 ? 1 : 0;
                    arm(3, 11 + dy, 5 - swing);
                    m(3, 16 + dy - swing, 2, 1, skin);
                } else {
                    arm(1, 10 + dy, 4);
                    m(1, 9 + dy, 2, 1, skin);
                }
                if (!right) {
                    const swing = f === 1 ? 1 : 0;
                    arm(11, 11 + dy, 5 - swing);
                    m(11, 16 + dy - swing, 2, 1, skin);
                } else if (f === 10 || f === 11) {
                    arm(13, f === 10 ? 4 + dy : 5 + dy, 6);
                    m(13, f === 10 ? 3 + dy : 4 + dy, 2, 1, skin);
                } else if (f === 6 || f === 8) {
                    arm(11, 11 + dy, 3);
                    m(10, 14 + dy, 3, 1, skin);
                    if (!back) {
                        m(8, 12 + dy, 3, 3, "#f4f4f4");
                        o(8, 12 + dy, 3, 1, "#6b4226");
                    }
                } else {
                    arm(11, 9 + dy, 4);
                    m(10, hy + 8, 2, 1, skin);
                    if (!back) {
                        m(7, hy + 6, 3, 3, "#f4f4f4");
                        o(7, hy + 6, 3, 1, "#e8e2d6");
                    }
                }
            }
        } else {
            if (f === 4 || f === 5) {
                sideArm(7, 11 + dy, 3, 3);
                m(4, 13 + dy, 4, 2, short ? skin : sleeveShade);
                m(3, f === 4 ? 13 + dy : 14 + dy, 1, 2, skin);
            } else if (f === 6 || f === 8) {
                sideArm(7, 11 + dy, 3, 3);
                m(5, 13 + dy, 3, 2, short ? skin : sleeveShade);
                m(4, 13 + dy, 1, 2, skin);
                m(2, 11 + dy, 3, 3, "#f4f4f4");
                o(2, 11 + dy, 3, 1, "#6b4226");
            } else if (f === 7 || f === 9) {
                sideArm(7, 9 + dy, 3, 4);
                m(5, hy + 7, 2, 1, skin);
                m(2, hy + 5, 3, 3, "#f4f4f4");
            } else if (f === 10 || f === 11) {
                sideArm(3, (f === 10 ? 5 : 6) + dy, 2, 7);
                m(3, (f === 10 ? 4 : 5) + dy, 2, 1, skin);
            } else if (f === 12) {
                m(4, 13 + dy, 4, 2, short ? skin : sleeveShade);
                m(1, 12 + dy, 4, 5, L.accent);
                o(2, 12 + dy, 2, 4, "#f6eedc");
            } else if (f === 13) {
                m(4, 12 + dy, 4, 2, short ? skin : sleeveShade);
                m(3, 11 + dy, 1, 2, skin);
            } else {
                const x = f === 1 ? 6 : f === 2 ? 8 : 7;
                sideArm(x, 11 + dy, 3, 5);
                m(x, 16 + dy, 3, 1, skin);
            }
        }

        // Neck and head.
        if (!side)
            m(7, 10 + dy, 2, 1, skin);
        if (side) {
            m(4, hy, 9, 9, skin);
            m(3, hy + 5, 1, 2, skin);
        } else {
            m(3, hy, 10, 9, skin);
        }

        // Hair and what is on the head.
        hairParts(L, hy, side, back, m, o, hair, hairDark, skin, skinDark);

        // Clothes.
        if (!side && !back) {
            if (top === "collared") {
                o(6, 11 + dy, 1, 1, "#ffffff");
                o(9, 11 + dy, 1, 1, "#ffffff");
                o(8, 13 + dy, 1, 1, shade(body, -0.25));
                o(8, 15 + dy, 1, 1, shade(body, -0.25));
            } else if (top === "tie") {
                o(7, 11 + dy, 2, 1, shade(L.accent, -0.2));
                o(7, 12 + dy, 2, 4, L.accent);
            } else if (top === "hoodie") {
                o(6, 12 + dy, 1, 2, "#f4f4f4");
                o(9, 12 + dy, 1, 2, "#f4f4f4");
                o(6, 15 + dy, 4, 1, shade(body, -0.18));
            } else if (top === "sweater") {
                o(5, 13 + dy, 6, 1, L.accent);
            } else if (top === "blazer") {
                o(7, 11 + dy, 2, 6, L.accent);
                o(6, 11 + dy, 1, 2, shade(body, -0.25));
                o(9, 11 + dy, 1, 2, shade(body, -0.25));
            } else if (top === "dress") {
                o(5, 15 + dy, 6, 1, L.accent);
            } else if (f !== 12 && f !== 6 && f !== 8) {
                o(7, 13 + dy, 2, 2, L.accent);
            }
            if (L.lanyard && f !== 12) {
                o(6, 11 + dy, 1, 2, "#3b82f6");
                o(9, 11 + dy, 1, 2, "#3b82f6");
                o(7, 13 + dy, 2, 2, "#ffffff");
            }
        } else if (back) {
            if (top === "hoodie")
                o(4, 11 + dy, 8, 2, shade(body, -0.2));
            else if (top === "collared" || top === "tie")
                o(5, 11 + dy, 6, 1, "#ffffff");
        } else if (top === "blazer" || top === "tie" || top === "collared") {
            o(5, 11 + dy, 2, 1, "#ffffff");
        }

        // Face.
        if (!back) {
            const eye = "#2b2233";
            if (!side) {
                if (f === 14) {
                    o(4, hy + 5, 2, 1, eye);
                    o(10, hy + 5, 2, 1, eye);
                } else {
                    o(5, hy + 4, 1, 2, eye);
                    o(10, hy + 4, 1, 2, eye);
                    if (L.lashes) {
                        o(4, hy + 4, 1, 1, eye);
                        o(11, hy + 4, 1, 1, eye);
                    }
                }
                if (L.blush)
                    o(4, hy + 6, 1, 1, "rgba(240,110,110,0.55)");
                if (L.blush)
                    o(11, hy + 6, 1, 1, "rgba(240,110,110,0.55)");
                if (L.beard === "beard") {
                    o(3, hy + 6, 1, 3, hair);
                    o(12, hy + 6, 1, 3, hair);
                    o(4, hy + 7, 8, 2, hair);
                    o(6, hy + 6, 4, 1, hair);
                } else if (L.beard === "moustache") {
                    o(6, hy + 6, 4, 1, hair);
                } else if (L.beard === "stubble") {
                    o(4, hy + 7, 8, 2, "rgba(40,30,30,0.18)");
                }
                const mouth = f === 13 ? "#5a2230" : L.lipstick ? "#c8324a" : shade(skin, -0.35);
                if (f !== 7 && f !== 9)
                    o(7, hy + 7, 2, f === 13 ? 2 : 1, mouth);
                if (L.glasses) {
                    const g = "#2b2233";
                    o(4, hy + 3, 3, 1, g);
                    o(9, hy + 3, 3, 1, g);
                    o(4, hy + 6, 3, 1, g);
                    o(9, hy + 6, 3, 1, g);
                    o(4, hy + 4, 1, 2, g);
                    o(6, hy + 4, 1, 2, g);
                    o(9, hy + 4, 1, 2, g);
                    o(11, hy + 4, 1, 2, g);
                    o(7, hy + 4, 2, 1, g);
                    o(5, hy + 4, 1, 1, "#d8ecff");
                    o(10, hy + 4, 1, 1, "#d8ecff");
                }
                if (L.earrings) {
                    o(2, hy + 6, 1, 2, "#f2c94c");
                    o(13, hy + 6, 1, 2, "#f2c94c");
                }
            } else {
                if (f === 14)
                    o(5, hy + 5, 2, 1, eye);
                else
                    o(5, hy + 4, 1, 2, eye);
                if (L.lashes && f !== 14)
                    o(4, hy + 4, 1, 1, eye);
                if (L.blush)
                    o(6, hy + 6, 1, 1, "rgba(240,110,110,0.55)");
                if (L.beard === "beard") {
                    o(4, hy + 7, 5, 2, hair);
                    o(8, hy + 5, 2, 3, hair);
                } else if (L.beard === "moustache") {
                    o(4, hy + 6, 2, 1, hair);
                } else if (L.beard === "stubble") {
                    o(4, hy + 7, 5, 2, "rgba(40,30,30,0.18)");
                }
                if (f !== 7 && f !== 9)
                    o(4, hy + 7, f === 13 ? 2 : 1, 1, f === 13 ? "#5a2230" : L.lipstick ? "#c8324a" : shade(skin, -0.35));
                if (L.glasses) {
                    o(4, hy + 3, 3, 1, "#2b2233");
                    o(4, hy + 6, 3, 1, "#2b2233");
                    o(4, hy + 4, 1, 2, "#2b2233");
                    o(6, hy + 4, 4, 1, "#2b2233");
                    o(5, hy + 4, 1, 1, "#d8ecff");
                }
                if (L.earrings)
                    o(9, hy + 6, 1, 2, "#f2c94c");
            }
        }
        return [U, M, O];
    }

    function hairParts(L, hy, side, back, m, o, hair, hairDark, skin, skinDark) {
        const s = L.style;
        const hatted = L.hat !== "";
        if (!side && !back) {
            if (!hatted) {
                switch (s) {
                case "short":
                    m(3, hy, 10, 2, hair);
                    m(3, hy + 2, 2, 2, hair);
                    m(11, hy + 2, 2, 1, hair);
                    m(5, hy + 2, 3, 1, hair);
                    break;
                case "sidepart":
                    m(3, hy, 10, 2, hair);
                    m(3, hy + 2, 7, 1, hair);
                    m(3, hy + 3, 1, 2, hair);
                    m(12, hy + 2, 1, 2, hair);
                    o(9, hy, 1, 2, hairDark);
                    break;
                case "spiky":
                    m(3, hy, 10, 2, hair);
                    m(4, hy - 1, 1, 1, hair);
                    m(6, hy - 1, 2, 1, hair);
                    m(9, hy - 1, 1, 1, hair);
                    m(11, hy - 1, 1, 1, hair);
                    m(3, hy + 2, 1, 2, hair);
                    m(12, hy + 2, 1, 2, hair);
                    m(5, hy + 2, 1, 1, hair);
                    m(8, hy + 2, 1, 1, hair);
                    break;
                case "buzz":
                    m(3, hy, 10, 1, hairDark);
                    o(3, hy + 1, 1, 2, hairDark);
                    o(12, hy + 1, 1, 2, hairDark);
                    break;
                case "bald":
                    o(5, hy + 1, 2, 1, shade(skin, 0.3));
                    o(3, hy + 4, 1, 2, hairDark);
                    o(12, hy + 4, 1, 2, hairDark);
                    break;
                case "curly":
                    m(2, hy - 1, 12, 4, hair);
                    m(2, hy + 3, 2, 3, hair);
                    m(12, hy + 3, 2, 3, hair);
                    o(4, hy, 1, 1, hairDark);
                    o(7, hy + 1, 1, 1, hairDark);
                    o(10, hy, 1, 1, hairDark);
                    o(5, hy + 2, 1, 1, hairDark);
                    o(9, hy + 2, 1, 1, hairDark);
                    break;
                case "mohawk":
                    m(6, hy - 1, 4, 3, hair);
                    o(3, hy + 1, 3, 1, skinDark);
                    o(10, hy + 1, 3, 1, skinDark);
                    break;
                case "long":
                    m(3, hy, 10, 3, hair);
                    m(2, hy + 1, 2, 10, hair);
                    m(12, hy + 1, 2, 10, hair);
                    m(4, hy + 3, 2, 1, hair);
                    o(7, hy, 1, 2, hairDark);
                    break;
                case "bob":
                    m(3, hy, 10, 3, hair);
                    m(2, hy + 1, 2, 7, hair);
                    m(12, hy + 1, 2, 7, hair);
                    break;
                case "ponytail":
                    m(3, hy, 10, 3, hair);
                    m(3, hy + 3, 1, 2, hair);
                    m(12, hy + 3, 1, 2, hair);
                    break;
                case "bun":
                    m(3, hy, 10, 3, hair);
                    m(6, hy - 1, 4, 2, hair);
                    m(3, hy + 3, 1, 1, hair);
                    m(12, hy + 3, 1, 1, hair);
                    o(6, hy + 1, 4, 1, hairDark);
                    break;
                case "pigtails":
                    m(3, hy, 10, 3, hair);
                    m(1, hy + 3, 2, 5, hair);
                    m(13, hy + 3, 2, 5, hair);
                    o(1, hy + 3, 2, 1, L.accent);
                    o(13, hy + 3, 2, 1, L.accent);
                    break;
                default:
                    m(3, hy, 10, 2, hair);
                    m(3, hy + 2, 5, 1, hair);
                    m(12, hy + 2, 1, 3, hair);
                    m(3, hy + 3, 1, 1, hair);
                }
            } else if (s === "long" || s === "bob" || s === "pigtails") {
                m(2, hy + 3, 2, s === "bob" ? 5 : 8, hair);
                m(12, hy + 3, 2, s === "bob" ? 5 : 8, hair);
            }
        } else if (back) {
            switch (s) {
            case "bald":
                o(3, hy + 5, 10, 2, hairDark);
                break;
            case "buzz":
                m(3, hy, 10, 7, hairDark);
                break;
            case "long":
                m(2, hy, 12, 12, hair);
                o(7, hy + 2, 1, 9, hairDark);
                break;
            case "bob":
                m(2, hy, 12, 8, hair);
                break;
            case "curly":
                m(2, hy - 1, 12, 10, hair);
                o(4, hy + 1, 1, 1, hairDark);
                o(9, hy + 3, 1, 1, hairDark);
                o(6, hy + 6, 1, 1, hairDark);
                break;
            case "mohawk":
                m(6, hy - 1, 4, 2, hair);
                o(6, hy + 1, 4, 7, hair);
                break;
            default:
                m(3, hy, 10, 8, hair);
                if (s === "ponytail")
                    m(7, hy + 7, 2, 5, hair);
                if (s === "bun")
                    m(6, hy - 1, 4, 2, hair);
                if (s === "pigtails") {
                    m(1, hy + 3, 2, 5, hair);
                    m(13, hy + 3, 2, 5, hair);
                }
                if (s === "spiky") {
                    m(4, hy - 1, 1, 1, hair);
                    m(7, hy - 1, 2, 1, hair);
                    m(11, hy - 1, 1, 1, hair);
                }
            }
        } else {
            switch (s) {
            case "bald":
                o(10, hy + 5, 3, 2, hairDark);
                break;
            case "buzz":
                m(4, hy, 9, 1, hairDark);
                o(10, hy + 1, 3, 4, hairDark);
                break;
            case "curly":
                m(3, hy - 1, 11, 4, hair);
                m(9, hy, 5, 8, hair);
                break;
            case "mohawk":
                m(6, hy - 1, 6, 2, hair);
                o(9, hy + 2, 3, 3, skinDark);
                break;
            default:
                m(4, hy, 9, 2, hair);
                m(9, hy + 2, 4, 4, hair);
                if (s === "short")
                    m(5, hy + 2, 2, 1, hair);
                if (s === "sidepart")
                    m(4, hy + 2, 4, 1, hair);
                if (s === "pixie")
                    m(4, hy + 2, 3, 1, hair);
                if (s === "spiky") {
                    m(5, hy - 1, 1, 1, hair);
                    m(8, hy - 1, 1, 1, hair);
                    m(11, hy - 1, 1, 1, hair);
                }
                if (s === "long") {
                    m(9, hy, 5, 11, hair);
                    m(4, hy + 2, 2, 1, hair);
                }
                if (s === "bob")
                    m(9, hy, 5, 8, hair);
                if (s === "ponytail") {
                    m(13, hy + 2, 2, 6, hair);
                    o(12, hy + 2, 1, 1, L.accent);
                }
                if (s === "bun")
                    m(11, hy - 1, 3, 3, hair);
                if (s === "pigtails")
                    m(12, hy + 4, 2, 6, hair);
            }
            if (s !== "long" && s !== "bob" && s !== "curly")
                o(9, hy + 4, 1, 2, skinDark);
        }

        // Hats, headphones, bows.
        if (L.hat === "beanie") {
            m(3, hy - 1, 10, 4, L.accent);
            o(3, hy + 2, 10, 1, shade(L.accent, -0.2));
            o(5, hy, 1, 2, shade(L.accent, 0.2));
        } else if (L.hat === "cap") {
            m(3, hy - 1, 10, 3, L.accent);
            if (side)
                m(1, hy + 1, 4, 1, shade(L.accent, -0.2));
            else if (!back)
                m(3, hy + 2, 10, 1, shade(L.accent, -0.2));
        }
        if (L.headphones) {
            m(3, hy - 1, 10, 1, "#2c2f38");
            if (side) {
                m(8, hy + 3, 3, 4, L.accent);
            } else {
                m(2, hy + 3, 2, 4, L.accent);
                m(12, hy + 3, 2, 4, L.accent);
            }
        }
        if (L.bow)
            m(side ? 7 : 10, hy - 1, 3, 2, L.accent);
    }

    // A pet's frame: the human frames map onto sitting, walking, pawing at a
    // keyboard, a tongue or open mouth for talking, and curling up to nap.
    function petFrame(L, f, d) {
        const U = [], M = [], O = [];
        const m = (x, y, w, h, c) => M.push([x, y, w, h, c]);
        const o = (x, y, w, h, c) => O.push([x, y, w, h, c]);
        const cat = L.species === "cat";
        const base = L.base, dark = L.dark, light = L.light;
        const earColor = L.earColor ?? (L.points ?? (cat ? base : dark));
        const tailColor = L.points ?? base;
        const pawColor = L.points ?? (L.chest || L.muzzle ? light : base);
        const walk = f === 1 || f === 2;
        const standing = walk || f === 0 || f === 13;
        const legs = L.short ? 2 : 3;
        let head = null, face = "front";
        if (f === 14) {
            U.push([2, 19, 12, 3, "rgba(0,0,0,0.25)"]);
            m(8, 19, 6, 2, tailColor);
            m(3, 15, 10, 6, base);
            m(3, 14, 6, 5, base);
            if (cat) {
                m(3, 12, 2, 2, earColor);
                m(7, 12, 2, 2, earColor);
            } else if (L.ears === "up") {
                m(3, 12, 2, 2, earColor);
                m(7, 12, 2, 2, earColor);
            } else {
                m(7, 14, 2, 4, earColor);
            }
            marks(L, o, {
                head: [3, 14, 6, 5],
                body: [7, 15, 6, 6],
                chest: null,
                muzzle: [3, 17, 4, 2],
                mask: [3, 15, 5, 3]
            });
            o(4, 16, 2, 1, "#2a2226");
            o(9, 20, 4, 1, shade(tailColor, -0.15));
            return [U, M, O];
        }
        U.push([3, 20, 10, 2, "rgba(0,0,0,0.25)"]);
        if (d === 1 && standing) {
            // Side, on four legs.
            const by = L.short ? 14 : 13;
            if (cat) {
                m(13, 7, 1, 7, tailColor);
                m(12, 6, 2, 2, tailColor);
            } else {
                m(13, by - 1 + (f === 2 ? 1 : 0), 2, 2, tailColor);
            }
            const front = f === 1 ? 3 : f === 2 ? 5 : 4;
            const hind = f === 1 ? 11 : f === 2 ? 9 : 10;
            m(front + 2, by + 5, 2, legs - 1, shade(base, -0.15));
            m(hind - 2, by + 5, 2, legs - 1, shade(base, -0.15));
            m(4, by, 9, 5, base);
            m(front, by + 5, 2, legs, base);
            m(hind, by + 5, 2, legs, base);
            o(front, by + 4 + legs, 2, 1, pawColor);
            o(hind, by + 4 + legs, 2, 1, pawColor);
            head = [1, by - 5, 6, 6];
            m(head[0], head[1], head[2], head[3], base);
            if (cat || L.ears === "up") {
                m(1, by - 7, 2, 2, earColor);
                m(4, by - 7, 2, 2, earColor);
                o(4, by - 6, 1, 1, "#e88a9a");
            }
            if (!cat)
                m(0, by - 2, 2, 3, L.muzzle ? light : base);
            face = "side";
            marks(L, o, {
                head: head,
                body: [4, by, 9, 5],
                chest: [4, by + 2, 3, 3],
                muzzle: [0, by - 2, 2, 3],
                mask: [1, by - 4, 4, 3],
                saddle: [6, by, 6, 2],
                paws: [[front, by + 4 + legs, 2, 1], [hind, by + 4 + legs, 2, 1]]
            });
            if (!cat && L.ears !== "up")
                m(4, by - 5, 2, 5, earColor);
            if (!cat)
                o(6, by, 1, 4, L.collar);
        } else if (d === 1) {
            // Side, sitting.
            m(11, 19, 4, 2, tailColor);
            m(6, 15, 7, 6, base);
            m(5, 12, 5, 7, base);
            m(5, 18, 2, 3, base);
            o(5, 20, 2, 1, pawColor);
            head = [2, 7, 7, 6];
            m(head[0], head[1], head[2], head[3], base);
            if (cat || L.ears === "up") {
                m(3, 5, 2, 2, earColor);
                m(6, 5, 2, 2, earColor);
            }
            if (!cat)
                m(1, 10, 2, 3, L.muzzle ? light : base);
            face = "side";
            marks(L, o, {
                head: head,
                body: [6, 15, 7, 6],
                chest: [5, 13, 2, 5],
                muzzle: [1, 10, 2, 3],
                mask: [2, 8, 4, 3],
                saddle: [8, 14, 4, 2],
                paws: [[5, 20, 2, 1]]
            });
            if (!cat && L.ears !== "up")
                m(6, 7, 2, 5, earColor);
            if (!cat)
                o(5, 13, 4, 1, L.collar);
            if (f === 4 || f === 10)
                m(3, 15, 2, 2, pawColor);
        } else {
            // Front or back, sitting (or standing, which looks much the same).
            const backView = d === 3;
            if (cat) {
                if (backView)
                    m(8, 19, 6, 2, tailColor);
                else {
                    m(11, 18, 4, 2, tailColor);
                    m(13, 14, 2, 4, tailColor);
                }
            } else {
                const wag = (f === 4 || f === 13 || f === 1) ? 1 : 0;
                m(backView ? 7 + wag : 12 + wag, backView ? 13 : 15, 2, 3, tailColor);
                if (L.curly && !backView)
                    o(12 + wag, 15, 1, 1, dark);
            }
            m(4, 16, 8, 5, base);
            m(5, 12, 6, 7, base);
            const pawsY = 21 - legs;
            const leftUp = f === 4 || f === 10, rightUp = f === 5 || f === 11;
            m(5, leftUp ? pawsY - 3 : pawsY, 2, legs, base);
            m(9, rightUp ? pawsY - 3 : pawsY, 2, legs, base);
            if (walk) {
                m(5, f === 1 ? pawsY - 1 : pawsY, 2, legs, base);
                m(9, f === 2 ? pawsY - 1 : pawsY, 2, legs, base);
            }
            head = [4, 7, 8, 6];
            m(head[0], head[1], head[2], head[3], base);
            if (cat || L.ears === "up") {
                m(4, 5, 2, 2, earColor);
                m(10, 5, 2, 2, earColor);
                if (cat) {
                    m(4, 4, 1, 1, earColor);
                    m(11, 4, 1, 1, earColor);
                }
                if (!backView) {
                    o(5, 6, 1, 1, "#e88a9a");
                    o(10, 6, 1, 1, "#e88a9a");
                }
            }
            if (!cat && !backView)
                m(6, 10, 4, 3, L.muzzle ? light : (L.face ?? shade(base, 0.12)));
            face = backView ? "back" : "front";
            marks(L, o, {
                head: head,
                body: [5, 12, 6, 7],
                chest: backView ? null : [7, 14, 2, 5],
                muzzle: backView ? null : [6, 10, 4, 3],
                mask: backView ? null : [5, 8, 6, 4],
                saddle: backView ? [5, 13, 6, 4] : null,
                paws: [[5, leftUp ? pawsY - 3 + legs - 1 : 20, 2, 1], [9, rightUp ? pawsY - 3 + legs - 1 : 20, 2, 1]]
            });
            if (!cat && L.ears !== "up") {
                m(2, 7, 2, 5, earColor);
                m(12, 7, 2, 5, earColor);
            }
            if (!cat) {
                o(5, 13, 6, 1, L.collar);
                if (!backView)
                    o(7, 14, 1, 1, "#f2c94c");
            }
        }
        // Face.
        const eye = L.eye ?? "#2a2226";
        if (face === "front") {
            if (f === 14) {
                o(5, 9, 2, 1, "#2a2226");
                o(9, 9, 2, 1, "#2a2226");
            } else if (cat) {
                o(5, 9, 2, 2, eye);
                o(9, 9, 2, 2, eye);
                o(6, 9, 1, 2, "#1b1a20");
                o(9, 9, 1, 2, "#1b1a20");
                o(7, 11, 2, 1, "#e88a9a");
                o(2, 11, 2, 1, "rgba(255,255,255,0.45)");
                o(12, 11, 2, 1, "rgba(255,255,255,0.45)");
                if (f === 13)
                    o(7, 12, 2, 1, "#5a2230");
            } else {
                o(5, 9, 1, 1, eye === "#2a2226" ? eye : eye);
                o(10, 9, 1, 1, eye);
                o(7, 10, 2, 1, "#2a2226");
                o(7, 12, 2, 1, shade(L.muzzle ? light : base, -0.4));
                if (f === 13)
                    m(7, 12, 2, 2, "#ef7d95");
            }
        } else if (face === "side") {
            const hx = head[0], hy = head[1];
            o(hx + 2, hy + 2, 1, cat ? 2 : 1, cat ? eye : "#2a2226");
            if (cat) {
                o(hx, hy + 4, 1, 1, "#e88a9a");
                if (f === 13)
                    o(hx, hy + 5, 2, 1, "#5a2230");
            } else {
                o(hx - 1, hy + 3, 1, 1, "#2a2226");
                if (f === 13)
                    o(hx, hy + 6, 2, 1, "#ef7d95");
            }
        }
        return [U, M, O];
    }

    // A breed's markings over the anchors a pose names.
    function marks(L, o, a) {
        const dark = L.dark;
        if (L.stripes && a.head) {
            o(a.head[0] + 2, a.head[1], 1, 2, dark);
            o(a.head[0] + a.head[2] - 3, a.head[1], 1, 2, dark);
            if (a.body) {
                for (let y = a.body[1] + 1; y < a.body[1] + a.body[3] - 1; y += 2)
                    o(a.body[0] + 1, y, a.body[2] - 2, 1, shade(L.base, -0.18));
            }
        }
        if (L.patches && a.head) {
            o(a.head[0], a.head[1], 3, 3, L.patches[0]);
            o(a.head[0] + a.head[2] - 3, a.head[1] + 1, 3, 2, L.patches[1]);
            if (a.body) {
                o(a.body[0] + a.body[2] - 3, a.body[1] + 1, 3, 3, L.patches[0]);
                o(a.body[0], a.body[1] + a.body[3] - 3, 2, 2, L.patches[1]);
            }
        }
        if (L.saddle && a.saddle)
            o(a.saddle[0], a.saddle[1], a.saddle[2], a.saddle[3], L.saddle);
        if (L.spots) {
            const spots = [[0, 1], [3, 2], [1, 4], [4, 0], [2, 3], [5, 3]];
            for (const r of [a.head, a.body]) {
                if (!r)
                    continue;
                for (const s of spots) {
                    if (s[0] < r[2] && s[1] < r[3])
                        o(r[0] + s[0], r[1] + s[1], 1, 1, dark);
                }
            }
        }
        if (L.chest && a.chest)
            o(a.chest[0], a.chest[1], a.chest[2], a.chest[3], L.light);
        if (L.muzzle && a.muzzle)
            o(a.muzzle[0], a.muzzle[1], a.muzzle[2], a.muzzle[3], L.light);
        if (L.mask && a.mask)
            o(a.mask[0], a.mask[1] + 1, a.mask[2], a.mask[3], L.light);
        if (L.face && a.mask)
            o(a.mask[0] + 1, a.mask[1] + 1, a.mask[2] - 2, a.mask[3], L.face);
        if (L.points) {
            if (a.mask)
                o(a.mask[0] + 1, a.mask[1] + 1, a.mask[2] - 2, a.mask[3], shade(L.points, 0.15));
            for (const p of a.paws ?? [])
                o(p[0], p[1], p[2], p[3], L.points);
        }
    }

    // Draws a whole sprite sheet into a canvas: 16×24 frames on an 18×26 grid,
    // so a scaled frame never samples the frame next to it.
    // A person's sheet: facing us, facing left and facing away, one row each;
    // facing right is the left row mirrored where it is shown.
    function paintSheet(ctx, look) {
        ctx.clearRect(0, 0, 270, 78);
        for (const [row, d] of [[0, 0], [1, 1], [2, 3]]) {
            for (let f = 0; f < 15; f++) {
                const parts = look.pet ? petFrame(look, f, d) : humanFrame(look, f, d);
                paintCell(ctx, parts, f * 18, row * 26, false);
            }
        }
    }

    // A person's sheet waits its turn to be painted.
    function queueSheet(view) {
        view.sheet = "queued";
        page.sheetQueue.push(view);
        page.sheetsPending++;
    }

    function dropSheet(view) {
        const i = page.sheetQueue.indexOf(view);
        if (i >= 0)
            page.sheetQueue.splice(i, 1);
        if (view.sheet === "queued" || view.sheet === "due")
            page.sheetsPending--;
        view.sheet = "";
    }

    // Asks the next sheets in the queue to be painted, one before it is known
    // what a sheet takes, then as many as the budget allows; a sheet whose
    // canvas cannot paint yet keeps its place.
    function paintSheets() {
        let n = page.sheetCost > 0 ? Math.max(1, Math.floor(page.sheetBudget / page.sheetCost)) : 1;
        const waiting = [];
        while (n > 0 && page.sheetQueue.length) {
            const view = page.sheetQueue.shift();
            if (!view.paintable) {
                waiting.push(view);
                continue;
            }
            view.sheet = "due";
            view.requestSheet();
            n--;
        }
        page.sheetQueue = waiting.concat(page.sheetQueue);
    }

    function sheetPainted(view, ms) {
        if (view.sheet !== "due")
            return;
        view.sheet = "painted";
        // Date.now() counts whole milliseconds; a sheet takes at least one.
        const cost = Math.max(1, ms);
        page.sheetCost = page.sheetCost > 0 ? 0.7 * page.sheetCost + 0.3 * cost : cost;
        page.sheetsPending--;
        settle(page.office);
    }

    // A mover's sheet: standing and two walking frames, empty-handed and then
    // carrying, in the four directions.
    function paintMoverSheet(ctx, look) {
        ctx.clearRect(0, 0, 108, 104);
        const carrying = Object.assign({}, look, {
            carry: true
        });
        for (const d of [0, 1, 3]) {
            for (let f = 0; f < 6; f++) {
                const parts = humanFrame(f < 3 ? look : carrying, f % 3, d);
                paintCell(ctx, parts, f * 18, d * 26, false);
                if (d === 1)
                    paintCell(ctx, parts, f * 18, 52, true);
            }
        }
    }

    // The desk a mover carries in front of it: a monitor and a chair on it,
    // legs down to the floor. It fits the mover's own figure, so it never
    // covers anyone around it.
    function paintLoad(ctx, chair) {
        ctx.clearRect(0, 0, 16, 14);
        const R = (c, x, y, w, h) => rect(ctx, c, x, y, w, h);
        const O = page.outline;
        R(O, 1, 9, 4, 5);
        R(O, 11, 9, 4, 5);
        R("#7a5530", 2, 10, 2, 4);
        R("#7a5530", 12, 10, 2, 4);
        R(O, 0, 6, 16, 5);
        R("#c99a64", 1, 7, 14, 2);
        R("#8f6538", 1, 9, 14, 1);
        R(O, 1, 0, 9, 7);
        R("#2b2f39", 2, 1, 7, 5);
        R("#141a24", 3, 2, 5, 3);
        R(O, 10, 1, 6, 6);
        R(chair, 11, 2, 4, 4);
        R(shade(chair, 0.18), 11, 2, 4, 1);
    }

    function paintCell(ctx, parts, ox, oy, mirror) {
        let style = null;
        const fill = (x, y, w, h, c) => {
            if (mirror)
                x = 16 - x - w;
            const x0 = Math.max(0, x), y0 = Math.max(0, y);
            const x1 = Math.min(16, x + w), y1 = Math.min(24, y + h);
            if (x1 <= x0 || y1 <= y0)
                return;
            if (c !== style) {
                ctx.fillStyle = c;
                style = c;
            }
            ctx.fillRect(ox + x0, oy + y0, x1 - x0, y1 - y0);
        };
        for (const r of parts[0])
            fill(r[0], r[1], r[2], r[3], r[4]);
        for (const r of parts[1])
            fill(r[0] - 1, r[1] - 1, r[2] + 2, r[3] + 2, page.outline);
        for (const r of parts[1])
            fill(r[0], r[1], r[2], r[3], r[4]);
        for (const r of parts[2])
            fill(r[0], r[1], r[2], r[3], r[4]);
    }

    // The icons over a head: a question, a failure, thinking, napping. Each sits
    // in a 16-wide cell of its own, so a scaled icon never samples its neighbour.
    function paintIcons(ctx) {
        ctx.clearRect(0, 0, 64, 11);
        const q = [[2, 0, 4, 1], [1, 1, 2, 2], [5, 1, 2, 3], [4, 4, 2, 1], [3, 5, 2, 2], [3, 8, 2, 2]];
        const bang = [[3, 0, 3, 6], [3, 7, 3, 2]];
        const z = [[1, 1, 6, 1], [5, 2, 2, 1], [4, 3, 2, 1], [3, 4, 2, 1], [2, 5, 2, 1], [1, 6, 6, 1]];
        const icon = (ox, rects, color) => {
            const parts = [[], rects.map(r => r.concat([color])), []];
            paintCell(ctx, parts, ox, 0, false);
        };
        icon(0, q, "#ffd84a");
        icon(16, bang, "#ff5a5a");
        // A thought bubble with three dots.
        paintCell(ctx, [[], [[0, 2, 9, 5, "#ffffff"], [1, 1, 7, 7, "#ffffff"], [1, 8, 2, 1, "#ffffff"]], [[2, 4, 1, 1, "#4b4a57"], [4, 4, 1, 1, "#4b4a57"], [6, 4, 1, 1, "#4b4a57"]]], 32, 0, false);
        icon(48, z, "#9cc8ff");
    }

    // ── The floor plan ──────────────────────────────────────────────────────
    //
    // Rows 0–2 are the wall, row 3 the furniture along it, then groups of desks
    // ("pods") from row 6: a pod is chairs, two rows of desks, chairs. Teams (a
    // thread and the workers under it) share pods of 4×2 desks; a bigger team
    // takes several. The office keeps one size, so adding a person never
    // repaints it: movers carry desks in through the entrance at the bottom
    // left and back out again. The break room is behind a wall with a door on
    // the right.

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
    // A team bigger than a pod takes as many as it needs. Whoever is left over
    // when every desk is taken has none, and spends the time in the break room.
    // Reviewers (`kind` "reviewer" in `byId`, their workers too, each by its
    // own kind) sit in the review corner, and once it is full at the desks
    // nearest it that nobody else needs, giving one up when someone else
    // needs it after all. The corner is theirs alone: nobody else ever takes
    // a desk there, and whoever sits there and is no reviewer leaves it.
    function seatTeams(teams, byId) {
        const w = page.world;
        const size = w.pods[0].seats.length;
        const before = w.seatOf ?? {};
        const seatOf = {};
        const taken = {};
        const room = pod => w.pods[pod].seats.filter(seat => !taken[seat.index]).length;
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

    // The office: six pods of 4×2 desks, three across and two down, the walls,
    // the furniture along them and the break room. The top pod by the break
    // room is the review corner, on a carpet of its own under a review sign
    // and the whiteboard where reviews are worked through. Every desk starts
    // out carried away (see furnish()).
    function buildWorld() {
        const podCols = 4, across = 3, down = 2;
        const workW = across * podCols + 2 * (across - 1);
        const xd = 3 + workW + 2;
        const bx = xd + 1;
        const cols = bx + 11;
        const rows = 6 + 6 * down + 1;
        const grid = new Array(cols * rows).fill(0);
        const at = (x, y) => y * cols + x;
        const block = (x, y, w, h) => {
            for (let j = y; j < y + h; j++)
                for (let i = x; i < x + w; i++)
                    grid[at(i, j)] = 1;
        };
        block(0, 0, cols, 3);
        block(0, 0, 1, rows);
        block(cols - 1, 0, 1, rows);
        block(0, rows - 1, cols, 1);
        block(xd, 0, 1, rows);
        grid[at(xd, 5)] = 0;
        grid[at(xd, 6)] = 0;

        const props = [], units = [], screens = [], boards = [], seats = [], spots = [], marks = [];
        const corner = across - 1;
        const prop = (kind, x, y, w, h, z, extra) => props.push(Object.assign({
            key: kind + ":" + x + ":" + y,
            kind: kind,
            x: x,
            y: y,
            w: w,
            h: h,
            z: z,
            seed: hash(kind + x + "," + y)
        }, extra ?? {}));

        // Pods: a row of chairs, two rows of desks, a row of chairs. Each seat
        // has its own desk and chair, which come and go together. A desk's
        // place is kept for it while it is out, so the way around the pods
        // never changes; a seat is stepped onto only by whoever is going there.
        const placed = [];
        for (let k = 0; k < down; k++) {
            const y0 = 6 + 6 * k;
            for (let c = 0; c < across; c++) {
                const x = 3 + c * (podCols + 2);
                const index = placed.length;
                const chair = pick(random(hash("chair" + index)), ["#3d4a63", "#4a3d63", "#2f5b52", "#63413d", "#3d5563"]);
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
                        grid[at(seat.x, seat.deskY)] = 1;
                        grid[at(seat.x, seat.y)] = 2;
                        units.push({
                            key: "desk:" + seat.index,
                            kind: north ? "deskN" : "deskS",
                            seat: seat.index,
                            x: seat.x * 16,
                            y: seat.deskY * 16,
                            w: 16,
                            h: 16,
                            z: (y0 + 3) * 16,
                            seed: hash("desk" + seat.index)
                        });
                        units.push({
                            key: "chair:" + seat.index,
                            kind: north ? "chairsN" : "chairsS",
                            seat: seat.index,
                            x: seat.x * 16,
                            y: seat.y * 16,
                            w: 16,
                            h: 16,
                            z: north ? (y0 + 1) * 16 - 2 : (y0 + 4) * 16 + 1,
                            color: chair,
                            seed: hash("chair" + seat.index)
                        });
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
        }

        // Along the top wall: bookshelves, whiteboards and plants.
        const sequence = ["plant", "shelf", "board", "shelf", "board", "plant", "shelf", "board"];
        let wx = 2;
        for (let i = 0; ; i++) {
            const kind = sequence[i % sequence.length];
            const w = kind === "shelf" ? 2 : kind === "board" ? 3 : 1;
            if (wx + w > xd - 1)
                break;
            block(wx, 3, w, 1);
            if (kind === "plant") {
                prop("plant", wx * 16, 64 - 30, 16, 30, 64);
            } else if (kind === "shelf") {
                prop("shelf", wx * 16, 64 - 44, 32, 44, 64);
                for (let j = 0; j < 2; j++)
                    spots.push({
                        x: wx + j,
                        y: 4,
                        face: 0,
                        offY: 0,
                        kind: "shelf",
                        pose: "book"
                    });
            } else {
                const key = "board:" + boards.length;
                const reviewPod = placed[corner];
                const review = wx + w > reviewPod.x && wx < reviewPod.x + reviewPod.cols;
                boards.push({
                    key: key,
                    x: wx * 16 + 5,
                    y: 64 - 40 + 5,
                    z: 64.5,
                    review: review
                });
                prop("board", wx * 16, 64 - 40, 48, 40, 64);
                for (let j = 0; j < 3; j++)
                    spots.push({
                        x: wx + j,
                        y: 4,
                        face: 3,
                        offY: 0,
                        kind: "board",
                        pose: "board",
                        board: key,
                        review: review
                    });
            }
            wx += w + 1;
        }

        // The far corner of the work area; the doorway and the floor around it
        // stay clear so people and movers meeting there can step aside.
        block(xd - 1, rows - 2, 1, 1);
        prop("plant", (xd - 1) * 16, (rows - 1) * 16 - 30, 16, 30, (rows - 1) * 16);

        // The break room.
        block(bx, 3, 10, 1);
        grid[at(bx + 4, 3)] = 0;
        prop("fridge", bx * 16, 64 - 42, 16, 42, 64);
        prop("counter", (bx + 1) * 16, 64 - 40, 48, 40, 64);
        prop("cooler", (bx + 5) * 16, 64 - 34, 16, 34, 64);
        prop("vending", (bx + 6) * 16, 64 - 44, 32, 44, 64);
        prop("arcade", (bx + 8) * 16, 64 - 42, 16, 42, 64);
        prop("plant", (bx + 9) * 16, 64 - 30, 16, 30, 64);
        const machine = (x, kind, cup) => spots.push({
                x: x,
                y: 4,
                face: 3,
                offY: 0,
                kind: kind,
                pose: kind === "arcade" ? "arcade" : "machine",
                cup: cup,
                area: "break"
            });
        machine(bx, "fridge", false);
        machine(bx + 1, "coffee", true);
        machine(bx + 5, "cooler", true);
        machine(bx + 6, "vending", false);
        machine(bx + 8, "arcade", false);

        // The round table and its chairs.
        block(bx + 2, 8, 2, 2);
        prop("table", (bx + 2) * 16, 8 * 16, 32, 32, 10 * 16);
        const tableSeat = (x, y, face, offY, z) => {
            grid[at(x, y)] = 2;
            prop("stool", x * 16, y * 16, 16, 16, z, {
                face: face
            });
            spots.push({
                x: x,
                y: y,
                face: face,
                offY: offY,
                kind: "table",
                pose: "sit",
                area: "break",
                seat: true
            });
        };
        tableSeat(bx + 2, 7, 0, 3, 8 * 16 - 2);
        tableSeat(bx + 3, 10, 3, -3, 11 * 16 + 1);
        tableSeat(bx + 1, 9, 2, 0, 10 * 16 - 2);
        tableSeat(bx + 4, 8, 1, 0, 9 * 16 - 2);

        // The couch, its coffee table and an armchair, on a rug.
        prop("couch", (bx + 6) * 16, 8 * 16 - 26, 48, 26, 8 * 16 - 1);
        for (let i = 0; i < 3; i++) {
            grid[at(bx + 6 + i, 7)] = 2;
            spots.push({
                x: bx + 6 + i,
                y: 7,
                face: 0,
                offY: -1,
                kind: "couch",
                pose: "sit",
                area: "break",
                seat: true
            });
        }
        block(bx + 6, 9, 2, 1);
        prop("coffeeTable", (bx + 6) * 16, 9 * 16, 32, 16, 10 * 16);
        grid[at(bx + 9, 9)] = 2;
        prop("armchair", (bx + 9) * 16, 9 * 16 - 6, 16, 22, 10 * 16 - 1);
        spots.push({
            x: bx + 9,
            y: 9,
            face: 1,
            offY: -1,
            kind: "armchair",
            pose: "sit",
            area: "break",
            seat: true
        });

        // A bed for the pets, places to stand and chat, plants.
        grid[at(bx + 8, 12)] = 2;
        prop("petBed", (bx + 8) * 16, 12 * 16, 16, 16, 13 * 16 - 2);
        spots.push({
            x: bx + 8,
            y: 12,
            face: 0,
            offY: 1,
            kind: "petBed",
            pose: "nap",
            area: "break",
            seat: true,
            pets: true
        });
        for (const pair of [[bx + 5, 12], [bx + 2, 13]]) {
            spots.push({
                x: pair[0],
                y: pair[1],
                face: 2,
                offY: 0,
                kind: "chat",
                pose: "chat",
                area: "break",
                partner: at(pair[0] + 1, pair[1])
            });
            spots.push({
                x: pair[0] + 1,
                y: pair[1],
                face: 1,
                offY: 0,
                kind: "chat",
                pose: "chat",
                area: "break",
                partner: at(pair[0], pair[1])
            });
        }
        for (const x of [bx, bx + 9]) {
            block(x, rows - 2, 1, 1);
            prop("plant", x * 16, (rows - 1) * 16 - 30, 16, 30, (rows - 1) * 16);
        }

        const review = placed[corner];
        return {
            cols: cols,
            rows: rows,
            grid: grid,
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
            spots: spots,
            props: props,
            units: units,
            screens: screens,
            boards: boards,
            door: [xd, 5],
            entrance: [2, rows - 2]
        };
    }

    function walkable(x, y) {
        const w = page.world;
        if (!w || x < 0 || y < 0 || x >= w.cols || y >= w.rows)
            return false;
        return w.grid[y * w.cols + x] === 0;
    }

    // ── Who is in the office ────────────────────────────────────────────────

    // Another machine's office: everyone leaves at once and its people come
    // in where they belong, at desks that are simply there. The room stays,
    // its whiteboards wiped.
    function reset() {
        for (const id of Object.keys(page.actors))
            removeActor(id);
        for (const id of Object.keys(page.movers))
            removeMover(id);
        page.jobs = [];
        page.outside = [];
        if (page.world) {
            page.world.seatOf = {};
            for (const seat of page.world.seats) {
                seat.mover = "";
                setDesk(seat, false);
            }
        }
        for (const board of Object.values(page.boardViews))
            board.progress = board.blank;
        countMoves();
        page.seen = {};
        page.arrival = {};
        page.claims = {};
        page.primed = false;
        page.settled = false;
        // `office` still holds the last machine's value while its change is
        // handled here.
        take(page.byEnvironment[page.environment] ?? null);
    }

    function take(value) {
        const people = value?.people ?? [];
        sync(people);
        hear(value?.talks ?? []);
        page.primed = value !== null && value !== undefined;
        updateWalking();
        settle(value);
    }

    // The office is settled once `value`, this machine's office, has been
    // drawn. Asked only where the people match `value`: after taking it and
    // after a paint, never from a binding, which sees the steps in between.
    function settle(value) {
        if (!page.settled && page.world && value && page.floorPaints > 0 && page.sheetsPending === 0)
            page.settled = true;
    }

    function sync(people) {
        if (!page.world)
            build();
        const byId = {};
        for (const person of people)
            byId[person.id] = person;
        for (const id of Object.keys(page.actors)) {
            if (!byId[id])
                removeActor(id);
        }
        for (const person of people) {
            if (page.arrival[person.id] === undefined)
                page.arrival[person.id] = page.arrivals++;
        }
        const order = people.map(p => p.id).sort((a, b) => page.arrival[a] - page.arrival[b]);
        layout(teamsOf(order, byId), byId);
        for (const person of people) {
            let actor = page.actors[person.id];
            if (!actor) {
                actor = newActor(person);
                page.actors[person.id] = actor;
                actorModel.append({
                    actorId: person.id
                });
                page.actorCount = actorModel.count;
            } else {
                actor.person = person;
            }
        }
        for (const id of Object.keys(page.actors)) {
            const actor = page.actors[id];
            if (actor.tx < 0)
                arrive(actor);
            decide(actor, false);
            render(actor);
        }
        updateMarks();
    }

    function build() {
        const w = buildWorld();
        page.world = w;
        page.occupied = new Array(w.cols * w.rows).fill("");
        page.worldCols = w.cols;
        page.worldRows = w.rows;
        page.props = w.props;
        page.units = w.units;
        page.screens = w.screens;
        page.boards = w.boards;
        page.deskMarks = w.marks;
        page.deskCount = 0;
        floor.requestPaint();
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
        // for a desk, or waiting for one, that is no longer theirs plans again,
        // and so does whoever waited in the break room for want of a desk and
        // now has one, or left its desk for a whiteboard or a shelf and has
        // none now.
        for (const id of Object.keys(page.actors)) {
            const actor = page.actors[id];
            const goal = actor.goal;
            if (goal?.deskless && seatOf[id] || (goal?.kind === "board" || goal?.kind === "shelf") && !seatOf[id]) {
                actor.goal = null;
                continue;
            }
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
            page.walking = true;
    }

    // A move that is no longer wanted: not started, or its mover heads out.
    function callOff(seat) {
        page.jobs = page.jobs.filter(i => i !== seat.index);
        const mover = page.movers[seat.mover];
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
        if (on !== was)
            page.deskCount += on ? 1 : -1;
        showDesk(seat);
        if (!on)
            return;
        const owner = Object.keys(w.seatOf).find(id => w.seatOf[id] === seat);
        const actor = owner ? page.actors[owner] : null;
        if (actor && actor.goal?.kind === "wait")
            decide(actor, true);
    }

    function deskShown(seat) {
        return seat.state === "in" || seat.state === "leaving";
    }

    function showDesk(seat) {
        const shown = deskShown(seat);
        for (const key of ["desk:" + seat.index, "chair:" + seat.index]) {
            const view = page.unitViews[key];
            if (view)
                view.visible = shown;
        }
        const screen = seat.screen ? page.screenViews[seat.screen] : null;
        if (screen)
            screen.visible = shown;
        const mark = page.world.marks[seat.index];
        if (mark)
            updateMark(mark);
    }

    // ── The project on each desk ────────────────────────────────────────────

    function updateMarks() {
        const w = page.world;
        if (!w)
            return;
        const owners = {};
        for (const id of Object.keys(w.seatOf))
            owners[w.seatOf[id].index] = id;
        for (const mark of w.marks)
            updateMark(mark, owners[mark.seat] ?? "");
    }

    // Shows the project of whoever has the desk, while it is in the office.
    // Reviewers hot-desk, so the corner's desks and any desk a reviewer has
    // show none. A mark is painted again only when its project's look changes.
    function updateMark(mark, owner) {
        const view = page.markViews[mark.key];
        if (!view)
            return;
        const w = page.world;
        const seat = w.seats[mark.seat];
        const id = owner ?? Object.keys(w.seatOf).find(each => w.seatOf[each] === seat) ?? "";
        const person = id ? page.actors[id]?.person : null;
        const hot = person?.kind === "reviewer" || !!w.pods[seat.pod]?.review;
        const sign = person && !hot ? signOf(person) : null;
        view.visible = !!sign?.kind && deskShown(seat);
        if (!sign)
            return;
        view.kind = sign.kind;
        view.label = sign.label;
        view.tint = sign.tint;
        view.emoji = sign.emoji;
        view.url = sign.url;
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
        rect(ctx, mix("#1c1f26", view.tint, 0.22), 0, 0, w, h);
        if (view.kind === "emoji")
            return;
        const glyphs = letters(view.label)?.slice(0, 2);
        if (glyphs?.length)
            paintLetters(ctx, glyphs, Math.floor((w - glyphs.length * 4 + 1) / 2), Math.floor((h - 5) / 2), view.tint);
        else
            rect(ctx, view.tint, Math.floor(w / 2) - 1, Math.floor(h / 2) - 1, 3, 3);
    }

    function everyone() {
        return Object.values(page.actors).concat(Object.values(page.movers));
    }

    function countMoves() {
        page.moves = page.jobs.length + Object.keys(page.movers).length;
    }

    // Someone to carry a desk walks in when the doorway is clear; four work
    // at once.
    function hire() {
        const w = page.world;
        const e = w.entrance;
        if (!page.jobs.length || Object.keys(page.movers).length >= 4 || !doorClear())
            return;
        const seat = w.seats[page.jobs.shift()];
        const id = "mover:" + page.moversHired++;
        const mover = newActor({
            id: id
        });
        mover.look = moverLook(id);
        mover.job = seat.index;
        mover.carrying = seat.state === "coming";
        mover.chair = seat.chair;
        seat.mover = id;
        page.movers[id] = mover;
        place(mover, e[0], e[1], false);
        mover.goal = {
            x: seat.x,
            y: seat.y,
            face: seat.face,
            offY: 0,
            pose: "stand",
            kind: "move"
        };
        route(mover, false);
        moverModel.append({
            moverId: id
        });
        countMoves();
    }

    // A mover walks to the desk's seat, waits for the desk's place to be clear,
    // sets the desk down or picks it up, and walks out again.
    function stepMover(mover, dt) {
        const w = page.world;
        const seat = mover.job >= 0 ? w.seats[mover.job] : null;
        const there = mover.goal && mover.tx === mover.goal.x && mover.ty === mover.goal.y && mover.next < 0;
        if (there && !seat) {
            removeMover(mover.id);
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
        } else if (mover.next < 0 && mover.path.length === 0 && page.ticks % 8 === 0) {
            route(mover, true);
        }
        const moving = step(mover, dt);
        mover.frame = mover.next >= 0 ? [1, 0, 2, 0][Math.floor(mover.dist / 5) % 4] : 0;
        renderMover(mover);
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
        route(mover, false);
    }

    function removeMover(id) {
        const mover = page.movers[id];
        if (!mover)
            return;
        const w = page.world;
        for (const i of [mover.ty * w.cols + mover.tx, mover.next]) {
            if (i >= 0 && page.occupied[i] === id)
                page.occupied[i] = "";
        }
        if (mover.job >= 0 && w.seats[mover.job].mover === id)
            w.seats[mover.job].mover = "";
        delete page.movers[id];
        for (let i = 0; i < moverModel.count; i++) {
            if (moverModel.get(i).moverId === id) {
                moverModel.remove(i);
                break;
            }
        }
        countMoves();
    }

    function renderMover(mover) {
        const v = page.moverViews[mover.id];
        if (!v)
            return;
        v.x = mover.px;
        v.y = mover.py - 8;
        v.z = mover.py + 16;
        v.frame = mover.frame;
        v.dir = mover.dir;
        v.carrying = mover.carrying;
    }

    // Movers wear the moving company's orange and its navy cap.
    function moverLook(id) {
        return Object.assign(lookFor({
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

    function newActor(person) {
        return {
            id: person.id,
            person: person,
            look: lookFor(person),
            tx: -1,
            ty: -1,
            px: 0,
            py: 0,
            offY: 0,
            next: -1,
            path: [],
            dir: 0,
            frame: 0,
            dist: 0,
            goal: null,
            plan: "",
            claim: -1,
            until: 0,
            stay: 0,
            cup: false,
            icon: "",
            bubble: "",
            bubbleUntil: 0,
            talk: null,
            queue: [],
            blocked: 0,
            waitingFor: "",
            heldBy: "",
            face: -1,
            faceUntil: 0,
            sideStep: false
        };
    }

    // A new person walks in through the door, waiting outside while someone is
    // in the doorway; the first people on the page are already where they belong.
    function arrive(actor) {
        if (!page.primed) {
            decide(actor, true);
            const goal = actor.goal;
            if (goal && !page.occupied[goal.y * page.world.cols + goal.x]) {
                place(actor, goal.x, goal.y, false);
                actor.path = [];
                return;
            }
        }
        if (!page.outside.includes(actor.id))
            page.outside.push(actor.id);
    }

    // Whether nobody stands in the doorway or on the floor next to it, so
    // whoever comes in can step off it.
    function doorClear() {
        const w = page.world;
        const [x, y] = w.entrance;
        return [[0, 0], [1, 0], [-1, 0], [0, -1]].every(([dx, dy]) => !walkable(x + dx, y + dy) || !page.occupied[(y + dy) * w.cols + x + dx]);
    }

    // The next person waiting outside walks in once the doorway is clear.
    function letIn() {
        while (page.outside.length && !page.actors[page.outside[0]])
            page.outside.shift();
        if (!page.outside.length || !doorClear())
            return;
        const actor = page.actors[page.outside.shift()];
        const e = page.world.entrance;
        place(actor, e[0], e[1], false);
        decide(actor, true);
        page.walking = true;
    }

    function place(actor, x, y, snap) {
        const w = page.world;
        const inside = x >= 0 && y >= 0 && x < w.cols && y < w.rows;
        const i = y * w.cols + x;
        if (!inside || snap && !(w.grid[i] === 0 || (actor.goal && actor.goal.x === x && actor.goal.y === y)) || page.occupied[i] && page.occupied[i] !== actor.id) {
            const free = nearestFree(x, y, actor.id);
            x = free[0];
            y = free[1];
        }
        actor.tx = x;
        actor.ty = y;
        actor.px = x * 16;
        actor.py = y * 16;
        actor.next = -1;
        page.occupied[y * w.cols + x] = actor.id;
    }

    // The nearest floor tile nobody stands on, nor, when `unclaimed`, is headed
    // for; with `unclaimed` and no such tile, null.
    function nearestFree(x, y, self, unclaimed) {
        const w = page.world;
        const seen = new Uint8Array(w.cols * w.rows);
        const queue = [[Math.max(0, Math.min(w.cols - 1, x)), Math.max(0, Math.min(w.rows - 1, y))]];
        seen[queue[0][1] * w.cols + queue[0][0]] = 1;
        while (queue.length) {
            const [cx, cy] = queue.shift();
            const i = cy * w.cols + cx;
            if (w.grid[i] === 0 && (!page.occupied[i] || page.occupied[i] === self) && (!unclaimed || !page.claims[i] || page.claims[i] === self))
                return [cx, cy];
            for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
                const nx = cx + dx, ny = cy + dy;
                if (nx >= 0 && ny >= 0 && nx < w.cols && ny < w.rows && !seen[ny * w.cols + nx]) {
                    seen[ny * w.cols + nx] = 1;
                    queue.push([nx, ny]);
                }
            }
        }
        return unclaimed ? null : [w.entrance[0], w.entrance[1]];
    }

    function removeActor(id) {
        const actor = page.actors[id];
        if (!actor)
            return;
        release(actor);
        if (page.world && actor.tx >= 0) {
            const i = actor.ty * page.world.cols + actor.tx;
            if (page.occupied[i] === id)
                page.occupied[i] = "";
            if (actor.next >= 0 && page.occupied[actor.next] === id)
                page.occupied[actor.next] = "";
        }
        delete page.actors[id];
        for (let i = 0; i < actorModel.count; i++) {
            if (actorModel.get(i).actorId === id) {
                actorModel.remove(i);
                break;
            }
        }
        page.actorCount = actorModel.count;
        if (page.hovered === id)
            page.hovered = "";
        for (const other of Object.values(page.actors)) {
            if (other.talk && other.talk.to === id)
                endTalk(other);
        }
    }

    // ── What each person does ───────────────────────────────────────────────

    function release(actor) {
        if (actor.claim >= 0 && page.claims[actor.claim] === actor.id)
            delete page.claims[actor.claim];
        actor.claim = -1;
    }

    function free(spot, actor) {
        const i = spot.y * page.world.cols + spot.x;
        const claim = page.claims[i];
        const there = page.occupied[i];
        return (!claim || claim === actor.id) && (!there || there === actor.id || !spot.seat && !page.actors[there]?.goal);
    }

    function claim(actor, spot) {
        release(actor);
        const i = spot.y * page.world.cols + spot.x;
        page.claims[i] = actor.id;
        actor.claim = i;
    }

    function seatGoal(actor, pose) {
        const seat = page.world.seatOf[actor.id];
        if (!seat) {
            // No desk yet: it waits in the break room, until it gets one.
            const goal = breakGoal(actor, true);
            goal.deskless = true;
            return goal;
        }
        if (seat.state !== "in")
            return waitGoal(actor, seat);
        release(actor);
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
                if (walkable(x, y) && free({
                    x: x,
                    y: y
                }, actor))
                    options.push([x, y]);
            }
        }
        const far = ([x, y]) => Math.abs(x - seat.x) + Math.abs(y - seat.y);
        options.sort((a, b) => far(a) - far(b));
        const spot = options[0] ?? nearestFree(pod.x - 1, pod.y + 1, actor.id, true);
        // With nowhere to wait, it plans again in a moment (see tick()).
        if (!spot) {
            release(actor);
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
        claim(actor, goal);
        return goal;
    }

    function spotGoal(actor, kind, pose) {
        let options = page.world.spots.filter(s => s.kind === kind && free(s, actor));
        // Reviewers plan at the review corner's whiteboard and everyone else
        // at the others, each at the other's when its own is taken.
        const own = options.filter(s => !!s.review === (actor.person?.kind === "reviewer"));
        if (own.length)
            options = own;
        if (!options.length)
            return null;
        const current = options.find(s => s.x === actor.goal?.x && s.y === actor.goal?.y);
        const spot = current ?? pick(page.rng, options);
        claim(actor, spot);
        return Object.assign({}, spot, {
            pose: pose ?? spot.pose
        });
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
        const options = page.world.spots.filter(s => s.area === "break" && weights[s.kind] && (!s.pets || pet) && free(s, actor));
        if (!options.length) {
            release(actor);
            const free = nearestFree(page.world.bx + 4 + Math.floor(page.rng() * 4), 11 + Math.floor(page.rng() * 3), actor.id);
            return {
                x: free[0],
                y: free[1],
                face: Math.floor(page.rng() * 4),
                offY: 0,
                pose: pet ? "sit" : "stand",
                kind: "floor"
            };
        }
        let total = 0;
        for (const s of options)
            total += weights[s.kind];
        let r = page.rng() * total;
        let spot = options[options.length - 1];
        for (const s of options) {
            r -= weights[s.kind];
            if (r <= 0) {
                spot = s;
                break;
            }
        }
        claim(actor, spot);
        let pose = spot.pose;
        if (spot.kind === "couch" || spot.kind === "armchair")
            pose = pet ? (page.rng() < 0.7 ? "nap" : "sit") : idle && page.rng() < 0.35 ? "nap" : "sit";
        return Object.assign({}, spot, {
            pose: pose
        });
    }

    // Works out where a person should be and what it does there, from its
    // thread's state, and sends it on its way when that changed.
    function decide(actor, force) {
        if (!page.world)
            return;
        if (actor.talk)
            return;
        const p = actor.person;
        const state = p.state;
        let plan = state;
        let goal = null;
        actor.icon = state === "asking" ? "ask" : state === "failed" ? "fail" : state === "working" && (p.activity === "thinking" || p.activity === "delegating") ? "think" : "";
        if (state === "asking" || state === "failed") {
            actor.cup = false;
            // Plans again only when it changed: a new goal claims a new spot.
            if (!force && actor.plan === plan && actor.goal)
                return;
            goal = seatGoal(actor, state === "asking" ? "ask" : "sit");
        } else if (state === "working") {
            const activity = p.activity ?? "";
            // A planner whose kind changes goes to its own kind's whiteboard.
            plan = "working:" + activity + (activity === "planning" ? ":" + (p.kind ?? "") : "");
            actor.cup = false;
            if (!force && actor.plan === plan && actor.goal)
                return;
            // Without a desk it waits in the break room whatever it does.
            const seated = !!page.world.seatOf[actor.id];
            if (seated && activity === "planning")
                goal = spotGoal(actor, "board");
            else if (seated && activity === "reading")
                goal = spotGoal(actor, "shelf");
            if (!goal)
                goal = seatGoal(actor, activity === "typing" || activity === "running" || activity === "testing" || activity === "browsing" ? "type" : "sit");
        } else {
            plan = "break";
            if (!force && actor.plan === plan && actor.goal && page.now < actor.until)
                return;
            goal = breakGoal(actor, state === "idle");
            const stage = goal.pose === "machine";
            // The stay starts once the person gets there (see tick()).
            actor.stay = stage ? between(page.rng, 3000, 5000) : goal.kind === "arcade" ? between(page.rng, 10000, 20000) : between(page.rng, 15000, 40000);
            actor.until = Infinity;
            if (!stage && goal.kind !== "table" && goal.kind !== "couch" && goal.kind !== "armchair" && goal.kind !== "chat")
                actor.cup = false;
        }
        actor.plan = plan;
        setGoal(actor, goal);
    }

    function setGoal(actor, goal) {
        const same = actor.goal && goal && actor.goal.x === goal.x && actor.goal.y === goal.y;
        actor.goal = goal;
        if (!goal || actor.tx < 0)
            return;
        if (!same || (actor.path.length === 0 && actor.next < 0 && (actor.tx !== goal.x || actor.ty !== goal.y)))
            route(actor, false);
        page.walking = true;
    }

    // Plans from the tile the person stands on, or the one it is stepping onto.
    function route(actor, avoid) {
        const goal = actor.goal;
        if (!goal)
            return;
        const W = page.world.cols;
        const sx = actor.next >= 0 ? actor.next % W : actor.tx;
        const sy = actor.next >= 0 ? (actor.next - sx) / W : actor.ty;
        actor.path = findPath(actor, sx, sy, goal.x, goal.y, avoid) ?? (avoid ? findPath(actor, sx, sy, goal.x, goal.y, false) ?? [] : []);
    }

    // A* over the tiles, four ways. Seats are entered only as the goal; with
    // `avoid`, tiles other people stand on are walls too.
    function findPath(actor, sx, sy, gx, gy, avoid) {
        const w = page.world;
        const W = w.cols, H = w.rows;
        const start = sy * W + sx, goal = gy * W + gx;
        if (start === goal)
            return [];
        const g = new Int32Array(W * H).fill(-1);
        const from = new Int32Array(W * H).fill(-1);
        const heap = [];
        const push = (f, i) => {
            heap.push([f, i]);
            let k = heap.length - 1;
            while (k > 0) {
                const parent = (k - 1) >> 1;
                if (heap[parent][0] <= heap[k][0])
                    break;
                [heap[parent], heap[k]] = [heap[k], heap[parent]];
                k = parent;
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
                if (j !== goal) {
                    if (w.grid[j] !== 0)
                        continue;
                    if (avoid && page.occupied[j] && page.occupied[j] !== actor.id)
                        continue;
                }
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
        const path = [];
        for (let i = goal; i !== start; i = from[i])
            path.push(i);
        return path.reverse();
    }

    // ── Talks ───────────────────────────────────────────────────────────────

    // New talks walk their speaker over. The first time the page sees an office,
    // only the talks of the last minute and a half are new.
    function hear(talks) {
        const fresh = Date.now() - 90000;
        for (const talk of talks) {
            if (!talk || page.seen[talk.id])
                continue;
            page.seen[talk.id] = true;
            if (!page.primed && Date.parse(talk.at) < fresh)
                continue;
            const from = page.actors[talk.from];
            if (!from || !page.actors[talk.to] || talk.from === talk.to)
                continue;
            // A speaker keeps at most three talks waiting. When they are full, a
            // talk to someone inside takes the place of the oldest one to
            // someone still outside the door.
            const outside = from.queue.findIndex(t => page.actors[t.to]?.tx < 0);
            if (from.queue.length >= 3 && outside >= 0 && !(page.actors[talk.to].tx < 0))
                from.queue.splice(outside, 1);
            if (from.queue.length < 3)
                from.queue.push(talk);
        }
    }

    // Starts the speaker's first talk whose listener is inside. One to someone
    // still outside the door waits its turn without holding up the rest.
    function startTalk(actor) {
        const next = actor.queue.findIndex(t => !(page.actors[t.to]?.tx < 0));
        if (next < 0)
            return;
        const talk = actor.queue.splice(next, 1)[0];
        if (!page.actors[talk.to])
            return;
        actor.talk = {
            to: talk.to,
            text: (talk.text ?? "").replace(/\s+/g, " ").slice(0, 120),
            kind: talk.kind,
            phase: "go",
            deadline: page.now + 25000,
            target: -1,
            until: 0,
            met: false
        };
        release(actor);
        actor.goal = null;
        page.walking = true;
    }

    function endTalk(actor) {
        const other = actor.talk ? page.actors[actor.talk.to] : null;
        if (other)
            other.face = -1;
        actor.talk = null;
        actor.bubble = "";
        actor.plan = "";
        decide(actor, true);
    }

    function replyOf(actor, kind) {
        if (actor.look.pet)
            return actor.look.species === "cat" ? qsTr("Meow!") : qsTr("Woof!");
        return kind === "delegate" ? qsTr("On it!") : kind === "result" ? qsTr("Thanks!") : qsTr("Sure!");
    }

    function stepTalk(actor) {
        const t = actor.talk;
        const other = page.actors[t.to];
        if (!other || page.now > t.deadline && t.phase === "go") {
            endTalk(actor);
            return;
        }
        const W = page.world.cols;
        const near = Math.abs(actor.tx - other.tx) + Math.abs(actor.ty - other.ty) === 1;
        if (t.phase === "go") {
            if (near && actor.next < 0) {
                // The other person stops once it finishes its step (see held()),
                // and the talk starts when both stand still side by side.
                t.met = true;
                other.heldBy = actor.id;
                if (other.next >= 0)
                    return;
                t.phase = "say";
                t.until = page.now + 5000;
                actor.path = [];
                actor.bubble = t.text;
                actor.bubbleUntil = t.until;
                return;
            }
            const there = other.ty * W + other.tx;
            if (t.target !== there || actor.path.length === 0 && actor.next < 0) {
                t.target = there;
                const sides = [[-1, 0], [1, 0], [0, -1], [0, 1]].map(([dx, dy]) => [other.tx + dx, other.ty + dy]).filter(([x, y]) => walkable(x, y) && (!page.occupied[y * W + x] || page.occupied[y * W + x] === actor.id));
                if (!sides.length)
                    return;
                sides.sort((a, b) => Math.abs(a[0] - actor.tx) + Math.abs(a[1] - actor.ty) - (Math.abs(b[0] - actor.tx) + Math.abs(b[1] - actor.ty)));
                const sidewaysFirst = sides.filter(s => s[1] === other.ty).concat(sides.filter(s => s[1] !== other.ty));
                const best = sidewaysFirst[0];
                actor.goal = {
                    x: best[0],
                    y: best[1],
                    face: 0,
                    offY: 0,
                    pose: "talk",
                    kind: "talk"
                };
                route(actor, false);
            }
            return;
        }
        if (!near) {
            endTalk(actor);
            return;
        }
        // Facing each other.
        actor.dir = dirTowards(actor, other);
        other.face = dirTowards(other, actor);
        if (t.phase === "say" && page.now >= t.until) {
            t.phase = "reply";
            t.until = page.now + 2200;
            actor.bubble = "";
            other.bubble = replyOf(other, t.kind);
            other.bubbleUntil = t.until;
        } else if (t.phase === "reply" && page.now >= t.until) {
            other.bubble = "";
            endTalk(actor);
        }
    }

    // Whether someone who walked up to talk to this person keeps it where it is.
    function held(actor) {
        const speaker = actor.heldBy ? page.actors[actor.heldBy] : null;
        return !!speaker && !!speaker.talk && speaker.talk.to === actor.id && speaker.talk.met;
    }

    function dirTowards(a, b) {
        const dx = b.tx - a.tx, dy = b.ty - a.ty;
        if (Math.abs(dx) >= Math.abs(dy) && dx !== 0)
            return dx < 0 ? 1 : 2;
        return dy < 0 ? 3 : 0;
    }

    // ── The clock ───────────────────────────────────────────────────────────

    // Runs the office n ticks of 40 ms at once (tests and previews).
    function advance(n) {
        for (let i = 0; i < n; i++)
            tick(40);
    }

    function tick(dt) {
        if (!page.world)
            return;
        page.now += dt;
        page.ticks++;
        let moving = false;
        for (const id of Object.keys(page.actors)) {
            const actor = page.actors[id];
            if (!actor.talk && actor.queue.length && actor.tx >= 0 && !held(actor))
                startTalk(actor);
            if (actor.talk)
                stepTalk(actor);
            else if (!actor.goal && actor.tx >= 0 && page.ticks % 8 === 0)
                decide(actor, true);
            else if (actor.plan === "break" && actor.next < 0 && actor.path.length === 0) {
                if (actor.until === Infinity) {
                    actor.until = page.now + actor.stay;
                } else if (page.now >= actor.until) {
                    if (actor.goal?.pose === "machine" && actor.goal.cup)
                        actor.cup = true;
                    decide(actor, true);
                }
            }
            if (actor.bubble && page.now >= actor.bubbleUntil && !(actor.talk && actor.talk.phase === "say"))
                actor.bubble = "";
            if (step(actor, dt))
                moving = true;
            pose(actor);
            render(actor);
        }
        letIn();
        hire();
        for (const id of Object.keys(page.movers)) {
            if (stepMover(page.movers[id], dt))
                moving = true;
        }
        if (page.ticks % 6 === 0)
            updateScreens();
        page.walking = moving || page.jobs.length > 0 || page.outside.length > 0;
    }

    function updateWalking() {
        page.walking = page.jobs.length > 0 || page.outside.length > 0 || everyone().some(a => a.next >= 0 || a.path.length > 0 || a.talk || a.queue.length);
    }

    // The walkable tiles beside a person that nobody holds.
    function freeSides(actor) {
        const W = page.world.cols;
        return [[1, 0], [-1, 0], [0, 1], [0, -1]].map(([dx, dy]) => [actor.tx + dx, actor.ty + dy]).filter(([x, y]) => walkable(x, y) && !page.occupied[y * W + x]);
    }

    // Moves a person along its path, two pixels a tick, holding the tile it
    // stands on and the one it steps to so nobody walks through anybody.
    function step(actor, dt) {
        const W = page.world.cols;
        if (actor.next < 0 && actor.path.length && held(actor))
            return false;
        if (actor.next < 0 && actor.path.length) {
            const n = actor.path[0];
            const there = page.occupied[n];
            if (there && there !== actor.id) {
                actor.blocked++;
                actor.waitingFor = there;
                // Two people walking into each other would both step around the
                // same way and meet again, so only one gives way: the one with
                // room to step aside, the first by id when both have it.
                const other = page.actors[there] ?? page.movers[there];
                const headOn = !!other && other.next < 0 && other.path.length > 0 && other.waitingFor === actor.id;
                const sides = freeSides(actor);
                const yields = !headOn || sides.length > 0 && (actor.id < other.id || freeSides(other).length === 0);
                if (yields && actor.blocked % 8 === 0 && actor.blocked < 30)
                    route(actor, true);
                if (actor.blocked >= 30) {
                    // Stepping aside makes room for someone waiting on this
                    // person; anyone else in the way is waited for, not paced
                    // in front of.
                    if (headOn && yields) {
                        const s = pick(page.rng, sides);
                        actor.path = [s[1] * W + s[0]];
                        actor.sideStep = true;
                    }
                    actor.blocked = 0;
                }
                return true;
            }
            page.occupied[n] = actor.id;
            actor.next = n;
            actor.path.shift();
            const nx = n % W, ny = (n - nx) / W;
            actor.dir = nx < actor.tx ? 1 : nx > actor.tx ? 2 : ny < actor.ty ? 3 : 0;
            actor.offY = 0;
            actor.blocked = 0;
            actor.waitingFor = "";
        }
        if (actor.next < 0)
            return false;
        const nx = actor.next % W, ny = (actor.next - nx) / W;
        const speed = Math.max(1, Math.round(dt / 20));
        const tx = nx * 16, ty = ny * 16;
        actor.px += Math.sign(tx - actor.px) * Math.min(speed, Math.abs(tx - actor.px));
        actor.py += Math.sign(ty - actor.py) * Math.min(speed, Math.abs(ty - actor.py));
        actor.dist += speed;
        if (actor.px === tx && actor.py === ty) {
            const old = actor.ty * W + actor.tx;
            if (page.occupied[old] === actor.id)
                page.occupied[old] = "";
            actor.tx = nx;
            actor.ty = ny;
            actor.next = -1;
            if (actor.sideStep && actor.path.length === 0) {
                actor.sideStep = false;
                if (actor.goal)
                    route(actor, true);
            }
        }
        return true;
    }

    // The frame a person shows: walking, or what it does where it is.
    function pose(actor) {
        const F = page.frame;
        const goal = actor.goal;
        const moving = actor.next >= 0 || actor.path.length > 0;
        const at = goal && actor.tx === goal.x && actor.ty === goal.y && !moving;
        if (actor.next >= 0) {
            actor.frame = [F.walk1, F.stand, F.walk2, F.stand][Math.floor(actor.dist / 5) % 4];
            return;
        }
        if (actor.talk && actor.talk.phase !== "go") {
            actor.frame = actor.talk.phase === "say" && Math.floor(page.now / 300) % 2 ? F.talk : F.stand;
            return;
        }
        if (actor.bubble && !actor.talk) {
            actor.frame = Math.floor(page.now / 300) % 2 ? F.talk : (at && goal.seat ? F.sit : F.stand);
            if (actor.face >= 0)
                actor.dir = actor.face;
            return;
        }
        if (!at) {
            actor.frame = F.stand;
            if (actor.face >= 0)
                actor.dir = actor.face;
            return;
        }
        actor.dir = actor.face >= 0 ? actor.face : goal.face;
        actor.offY = goal.offY ?? 0;
        const t = page.now;
        switch (goal.pose) {
        case "type":
            actor.frame = Math.floor(t / 240) % 2 ? F.type1 : F.type2;
            break;
        case "ask":
            actor.frame = t % 3200 < 500 ? F.raise1 : F.stand;
            break;
        case "book":
            actor.frame = F.book;
            break;
        case "board":
            actor.frame = Math.floor(t / 420) % 2 ? F.raise1 : F.raise2;
            break;
        case "arcade":
            actor.frame = Math.floor(t / 260) % 2 ? F.type1 : F.type2;
            break;
        case "machine":
            actor.frame = F.stand;
            break;
        case "nap":
            actor.frame = F.nap;
            break;
        case "chat":
            {
                const partner = page.occupied[goal.partner];
                const there = partner && page.actors[partner];
                const talking = there && there.goal?.kind === "chat" && there.tx === there.goal.x && there.ty === there.goal.y;
                actor.frame = actor.cup ? (t % 4000 < 700 ? F.sip : F.cup) : talking && Math.floor((t + (goal.face === 1 ? 900 : 0)) / 1800) % 2 ? F.talk : F.stand;
                break;
            }
        case "stand":
            actor.frame = actor.cup ? (t % 4000 < 700 ? F.sip : F.cup) : F.stand;
            break;
        default:
            actor.frame = actor.cup ? (t % 4500 < 800 ? F.sitSip : F.sitCup) : F.sit;
        }
        if (actor.face >= 0 && goal.seat && goal.kind === "desk")
            actor.dir = actor.face;
    }

    function iconOf(actor) {
        if (actor.goal?.pose === "nap" && actor.tx === actor.goal.x && actor.ty === actor.goal.y)
            return "nap";
        return actor.icon;
    }

    function render(actor) {
        const inside = actor.tx >= 0;
        const v = page.views[actor.id];
        if (v) {
            v.visible = inside;
            v.x = actor.px;
            v.y = actor.py - 8 + actor.offY;
            v.z = actor.py + 16;
            v.frame = actor.frame;
            v.dir = actor.dir;
        }
        const o = page.overlays[actor.id];
        if (o) {
            o.visible = inside;
            o.anchorX = actor.px + 8;
            o.anchorY = actor.py - 8 + actor.offY + (page.seated(actor.frame) ? 2 : 0);
            o.icon = actor.bubble ? "" : iconOf(actor);
            o.bubble = actor.bubble;
            o.bob = Math.floor(page.now / 300) % 2;
        }
    }

    function updateScreens() {
        if (!page.world)
            return;
        for (const screen of page.screens) {
            const view = page.screenViews[screen.key];
            if (!view)
                continue;
            const seat = page.world.seats[screen.seat];
            view.visible = deskShown(seat);
            const owner = page.occupied[seat.y * page.world.cols + seat.x];
            const actor = owner ? page.actors[owner] : null;
            let mode = "off";
            if (actor && actor.goal?.kind === "desk") {
                const p = actor.person;
                mode = p.state === "failed" ? "failed" : p.state === "working" ? (p.activity ?? "idle") : "idle";
            }
            view.mode = mode;
            view.phase = page.ticks / 6;
        }
        for (const board of page.boards) {
            const view = page.boardViews[board.key];
            if (!view)
                continue;
            const drawing = Object.values(page.actors).some(a => a.goal?.board === board.key && a.tx === a.goal.x && a.ty === a.goal.y);
            if (drawing)
                view.progress = Math.min(1, view.progress + 0.02);
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

    // ── Painting the room ───────────────────────────────────────────────────

    function rect(ctx, c, x, y, w, h) {
        ctx.fillStyle = c;
        ctx.fillRect(x, y, w, h);
    }

    // A 3×5 pixel letter, as five rows of three bits (the left one 4), or
    // undefined for one the office has no letter for.
    readonly property var glyphs: ({
            A: [2, 5, 7, 5, 5],
            B: [6, 5, 6, 5, 6],
            C: [3, 4, 4, 4, 3],
            D: [6, 5, 5, 5, 6],
            E: [7, 4, 6, 4, 7],
            F: [7, 4, 6, 4, 4],
            G: [3, 4, 5, 5, 3],
            H: [5, 5, 7, 5, 5],
            I: [7, 2, 2, 2, 7],
            J: [1, 1, 1, 5, 2],
            K: [5, 5, 6, 5, 5],
            L: [4, 4, 4, 4, 7],
            M: [5, 7, 7, 5, 5],
            N: [6, 5, 5, 5, 5],
            O: [2, 5, 5, 5, 2],
            P: [6, 5, 6, 4, 4],
            Q: [2, 5, 5, 7, 3],
            R: [6, 5, 6, 5, 5],
            S: [3, 4, 2, 1, 6],
            T: [7, 2, 2, 2, 2],
            U: [5, 5, 5, 5, 7],
            V: [5, 5, 5, 5, 2],
            W: [5, 5, 7, 7, 5],
            X: [5, 5, 2, 5, 5],
            Y: [5, 5, 2, 2, 2],
            Z: [7, 1, 2, 4, 7],
            "0": [7, 5, 5, 5, 7],
            "1": [2, 6, 2, 2, 7],
            "2": [6, 1, 2, 4, 7],
            "3": [6, 1, 2, 1, 6],
            "4": [5, 5, 7, 1, 1],
            "5": [7, 4, 6, 1, 6],
            "6": [3, 4, 6, 5, 2],
            "7": [7, 1, 1, 2, 2],
            "8": [2, 5, 2, 5, 2],
            "9": [2, 5, 3, 1, 6]
        })

    // The pixel letters of `text`, accents dropped, or null when one has
    // none.
    function letters(text) {
        const out = [];
        for (const ch of String(text).normalize("NFD").replace(/[\u0300-\u036f]/g, "").toUpperCase()) {
            const glyph = page.glyphs[ch];
            if (!glyph)
                return null;
            out.push(glyph);
        }
        return out;
    }

    // Draws pixel letters (from letters()) at x, y, a column apart.
    function paintLetters(ctx, glyphs, x, y, c) {
        ctx.fillStyle = c;
        glyphs.forEach((glyph, i) => {
            for (let row = 0; row < 5; row++) {
                for (let col = 0; col < 3; col++) {
                    if (glyph[row] & (4 >> col))
                        ctx.fillRect(x + i * 4 + col, y + row, 1, 1);
                }
            }
        });
    }

    function sky(hour) {
        if (hour >= 7 && hour < 17)
            return ["#7cc4f2", "#a8dbfa", "#ffffff"];
        if (hour >= 17 && hour < 20)
            return ["#f08a5d", "#f7c08a", "#ffe4b5"];
        if (hour >= 5 && hour < 7)
            return ["#f4a7b9", "#fbd3c0", "#fff1e0"];
        return ["#1d2547", "#2b3566", "#f6f1c7"];
    }

    function paintFloor(ctx) {
        const w = page.world;
        if (!w)
            return;
        const W = w.cols * 16, H = w.rows * 16;
        ctx.clearRect(0, 0, W, H);
        const xd = w.xd, bx = w.bx;
        // Carpet in the work area, wooden planks in the break room.
        for (let y = 3; y < w.rows; y++) {
            for (let x = 0; x < w.cols; x++) {
                if (x < xd) {
                    rect(ctx, (x + y) % 2 ? "#4d5b74" : "#52617b", x * 16, y * 16, 16, 16);
                    rect(ctx, "rgba(255,255,255,0.03)", x * 16, y * 16, 16, 1);
                } else {
                    const shift = (y % 2) * 8;
                    rect(ctx, y % 2 ? "#b88654" : "#bd8b58", x * 16, y * 16, 16, 16);
                    rect(ctx, "#a2733f", x * 16, y * 16 + 15, 16, 1);
                    rect(ctx, "#a2733f", x * 16 + shift, y * 16 + 2, 1, 13);
                    if ((x * 7 + y * 3) % 5 === 0)
                        rect(ctx, "#c99a66", x * 16 + 3, y * 16 + 6, 3, 1);
                }
            }
        }
        // A rug under the couch, and one under the table.
        const rug = (x, y, ww, hh, c1, c2) => {
            rect(ctx, c2, x, y, ww, hh);
            rect(ctx, c1, x + 2, y + 2, ww - 4, hh - 4);
            for (let i = x + 4; i < x + ww - 4; i += 6)
                rect(ctx, c2, i, y + hh / 2 - 1, 3, 2);
        };
        rug((bx + 5) * 16 + 4, 6 * 16 + 8, 5 * 16 - 8, 4 * 16 + 2, "#9b4d5a", "#7a3442");
        rug((bx + 1) * 16 + 2, 7 * 16 + 4, 4 * 16 - 4, 4 * 16 - 6, "#4d7a6b", "#365a4e");
        // The review corner's carpet, green with a border.
        const v = w.review;
        for (let y = v.y; y < v.y + v.h; y++) {
            for (let x = v.x; x < v.x + v.w; x++)
                rect(ctx, (x + y) % 2 ? "#4b6a5f" : "#507065", x * 16, y * 16, 16, 16);
        }
        rect(ctx, "#3b5449", v.x * 16, v.y * 16, v.w * 16, 2);
        rect(ctx, "#3b5449", v.x * 16, (v.y + v.h) * 16 - 2, v.w * 16, 2);
        rect(ctx, "#3b5449", v.x * 16, v.y * 16, 2, v.h * 16);
        // Shadow under the top wall.
        rect(ctx, "rgba(0,0,0,0.18)", 0, 48, W, 3);
        rect(ctx, "rgba(0,0,0,0.08)", 0, 51, W, 3);
        // The top wall.
        rect(ctx, "#4a4038", 0, 0, W, 6);
        rect(ctx, "#ddd3c3", 0, 6, xd * 16, 38);
        rect(ctx, "#e9dcb8", bx * 16, 6, W - bx * 16, 38);
        rect(ctx, "rgba(0,0,0,0.05)", 0, 6, W, 2);
        rect(ctx, "#8a7a68", 0, 44, W, 4);
        rect(ctx, "#a08e7a", 0, 44, W, 1);
        // Windows over the work area, the sky as it is now.
        const colors = sky(new Date().getHours());
        const night = colors[0] === "#1d2547";
        for (let x = 3; x + 3 < xd - 1; x += 7) {
            const wx = x * 16 + 4, wy = 10, ww = 40, wh = 26;
            rect(ctx, "#f4f1ea", wx - 2, wy - 2, ww + 4, wh + 4);
            rect(ctx, colors[0], wx, wy, ww, wh);
            rect(ctx, colors[1], wx, wy + wh - 8, ww, 8);
            if (night) {
                rect(ctx, colors[2], wx + 7, wy + 5, 1, 1);
                rect(ctx, colors[2], wx + 29, wy + 9, 1, 1);
                rect(ctx, colors[2], wx + 18, wy + 3, 1, 1);
                rect(ctx, colors[2], wx + 33, wy + 4, 3, 3);
            } else {
                rect(ctx, colors[2], wx + 6 + (x % 3) * 4, wy + 6, 8, 2);
                rect(ctx, colors[2], wx + 8 + (x % 3) * 4, wy + 5, 4, 1);
            }
            // A skyline at the bottom.
            const city = night ? "#141a33" : "#8aa5bd";
            rect(ctx, city, wx, wy + wh - 6, 8, 6);
            rect(ctx, city, wx + 9, wy + wh - 10, 6, 10);
            rect(ctx, city, wx + 17, wy + wh - 4, 7, 4);
            rect(ctx, city, wx + 26, wy + wh - 8, 5, 8);
            rect(ctx, city, wx + 33, wy + wh - 5, 7, 5);
            if (night) {
                rect(ctx, "#f6d36b", wx + 11, wy + wh - 8, 1, 1);
                rect(ctx, "#f6d36b", wx + 28, wy + wh - 6, 1, 1);
            }
            rect(ctx, "#f4f1ea", wx + ww / 2 - 1, wy, 2, wh);
            rect(ctx, "#f4f1ea", wx, wy + 11, ww, 2);
            rect(ctx, "rgba(255,255,255,0.25)", wx + 2, wy + 2, 3, 7);
            rect(ctx, "#cfc8bb", wx - 3, wy + wh + 2, ww + 6, 2);
        }
        // A clock and a poster in the break room.
        const cx = (bx + 4) * 16 + 2, cy = 14;
        rect(ctx, "#2f2a28", cx + 2, cy - 1, 8, 14);
        rect(ctx, "#2f2a28", cx - 1, cy + 2, 14, 8);
        rect(ctx, "#2f2a28", cx, cy, 12, 12);
        rect(ctx, "#fbf8f1", cx + 1, cy + 1, 10, 10);
        rect(ctx, "#fbf8f1", cx + 3, cy, 6, 12);
        rect(ctx, "#fbf8f1", cx, cy + 3, 12, 6);
        rect(ctx, "#2f2a28", cx + 5, cy + 2, 1, 4);
        const hour = new Date().getHours() % 12;
        const hand = [[0, -3], [1, -3], [2, -2], [3, 0], [2, 2], [1, 3], [0, 3], [-1, 3], [-2, 2], [-3, 0], [-2, -2], [-1, -3]][hour];
        rect(ctx, "#c0392b", cx + 5 + Math.sign(hand[0]), cy + 5 + Math.sign(hand[1]), 1, 1);
        rect(ctx, "#c0392b", cx + 5 + hand[0], cy + 5 + hand[1], 1, 1);
        rect(ctx, "#2f2a28", cx + 5, cy + 5, 2, 2);
        const px = (bx + 2) * 16 + 8;
        rect(ctx, "#f2ede4", px - 1, 9, 22, 28);
        rect(ctx, "#e8894a", px, 10, 20, 26);
        rect(ctx, "#f8c25c", px + 4, 14, 12, 12);
        rect(ctx, "#fbe7a1", px + 7, 17, 6, 6);
        rect(ctx, "#3d4451", px + 3, 29, 14, 2);
        // A poster and a framed picture in the work area, between the windows.
        for (let x = 6; x + 3 < xd - 1; x += 14) {
            const qx = x * 16 + 14;
            rect(ctx, "#2f2a28", qx - 1, 11, 16, 22);
            rect(ctx, "#4a90d9", qx, 12, 14, 20);
            rect(ctx, "#f2efe8", qx + 3, 16, 8, 3);
            rect(ctx, "#f2efe8", qx + 5, 21, 4, 8);
        }
        // The review corner's sign, on the wall beside its whiteboard.
        const sx = (xd - 2) * 16 + 1, sy = 14;
        rect(ctx, "#2f2a28", sx + 6, sy - 5, 1, 5);
        rect(ctx, "#2f2a28", sx + 23, sy - 5, 1, 5);
        rect(ctx, page.outline, sx - 1, sy - 1, 32, 13);
        rect(ctx, "#2f7a55", sx, sy, 30, 11);
        rect(ctx, "#3f9a6c", sx, sy, 30, 1);
        paintLetters(ctx, page.letters("REVIEW"), sx + 4, sy + 3, "#f2efe8");
        // A check mark under it.
        for (const [dx, dy] of [[0, 1], [1, 2], [2, 1], [3, 0], [4, -1]])
            rect(ctx, "#5fd38a", sx + 12 + dx, sy + 20 + dy, 2, 2);
        // The side, bottom and middle walls.
        const wall = (x, y, ww, hh) => {
            rect(ctx, "#4a4038", x, y, ww, hh);
            rect(ctx, "#5d544b", x + 2, y, ww - 4, hh);
            rect(ctx, "#6c6258", x + 3, y, ww - 6, 1);
        };
        wall(0, 40, 16, H - 40);
        wall(W - 16, 40, 16, H - 40);
        rect(ctx, "#4a4038", 0, H - 16, W, 16);
        rect(ctx, "#5d544b", 0, H - 14, W, 12);
        rect(ctx, "#6c6258", 0, H - 14, W, 1);
        wall(xd * 16, 40, 16, 5 * 16 - 40);
        wall(xd * 16, 7 * 16, 16, H - 7 * 16);
        // The door to the break room, and a mat at the way in.
        rect(ctx, "#8a6a48", xd * 16, 5 * 16, 2, 32);
        rect(ctx, "#8a6a48", xd * 16 + 14, 5 * 16, 2, 32);
        rect(ctx, "rgba(0,0,0,0.12)", xd * 16 + 2, 5 * 16, 12, 32);
        const e = w.entrance;
        rect(ctx, "#6b4a2f", e[0] * 16 - 8, (e[1] + 1) * 16 - 2, 32, 4);
        rect(ctx, "#3f6b5c", e[0] * 16 - 6, e[1] * 16 + 4, 28, 10);
        rect(ctx, "#4f8070", e[0] * 16 - 4, e[1] * 16 + 6, 24, 6);
    }

    function paintProp(ctx, p) {
        ctx.clearRect(0, 0, p.w, p.h);
        const r = random(p.seed);
        const R = (c, x, y, w, h) => rect(ctx, c, x, y, w, h);
        const O = page.outline;
        switch (p.kind) {
        case "deskN":
            // A north seat's desk: its keyboard by the chair, the back of its
            // monitor and the low divider to the desk across.
            R(O, 0, 0, 16, 16);
            R("#c99a64", 1, 1, 14, 11);
            R("#ddb27c", 1, 1, 14, 1);
            R("#6f8584", 1, 12, 14, 3);
            R("#8aa09f", 1, 12, 14, 1);
            R("#d7dbe2", 4, 1, 8, 2);
            R("#b9bec8", 4, 2, 8, 1);
            R(O, 2, 3, 11, 9);
            R("#3b404d", 3, 4, 9, 7);
            R("#4b5160", 3, 4, 9, 1);
            if (r() < 0.3) {
                R(O, 13, 4, 3, 4);
                R(pick(r, ["#e8894a", "#5a6fd6", "#f2efe8"]), 13, 5, 2, 2);
            }
            break;
        case "deskS":
            {
                // A south seat's desk: the front of its monitor (its screen
                // is drawn over it), a keyboard and a mouse.
                R("rgba(0,0,0,0.25)", 1, 14, 14, 2);
                R(O, 0, 0, 16, 14);
                R("#c99a64", 1, 1, 14, 10);
                R("#8f6538", 1, 11, 14, 2);
                R("#7a5530", 1, 12, 14, 1);
                R(O, 2, 0, 12, 9);
                R("#2b2f39", 3, 0, 10, 8);
                R("#141a24", 4, 1, 8, 6);
                R("#5d6372", 6, 9, 4, 1);
                R("#e3e6ec", 3, 10, 8, 1);
                R("#e3e6ec", 12, 10, 2, 1);
                const thing = r();
                if (thing < 0.25) {
                    R(O, 0, 3, 3, 5);
                    R(pick(r, ["#e05d5d", "#4a90d9", "#e8c14a", "#f2efe8"]), 1, 4, 1, 3);
                } else if (thing < 0.45) {
                    R("#3a9a68", 13, 2, 3, 2);
                    R("#4fbf85", 13, 3, 3, 3);
                    R("#7a4a2a", 14, 6, 2, 2);
                }
                break;
            }
        case "chairsN":
        case "chairsS":
            {
                const north = p.kind === "chairsN";
                for (let i = 0; i < p.w / 16; i++) {
                    const x = i * 16;
                    if (north) {
                        R(O, x + 3, 0, 10, 13);
                        R(p.color, x + 4, 1, 8, 6);
                        R(shade(p.color, 0.18), x + 4, 1, 8, 1);
                        R(shade(p.color, 0.1), x + 4, 8, 8, 4);
                        R("#2b2f39", x + 7, 13, 2, 2);
                    } else {
                        R("#2b2f39", x + 4, 14, 8, 1);
                        R("#2b2f39", x + 7, 12, 2, 2);
                        R(O, x + 2, 4, 11, 9);
                        R(p.color, x + 3, 5, 9, 7);
                        R(shade(p.color, 0.18), x + 3, 5, 9, 1);
                    }
                }
                break;
            }
        case "shelf":
            {
                R("rgba(0,0,0,0.25)", 1, 42, 30, 2);
                R(O, 0, 0, 32, 43);
                R("#7a5232", 1, 1, 30, 41);
                R("#4a3220", 3, 4, 26, 36);
                R("#8f6440", 1, 1, 30, 2);
                const books = ["#c0392b", "#2f6f9f", "#e8c14a", "#3fa58f", "#8e62c9", "#e8894a", "#f2efe8", "#3d4451", "#d36ba6"];
                for (let s = 0; s < 3; s++) {
                    const base = 4 + s * 12 + 11;
                    R("#8f6440", 3, base, 26, 2);
                    let x = 3;
                    while (x < 28) {
                        const bw = r() < 0.3 ? 3 : 2;
                        const bh = 7 + Math.floor(r() * 3);
                        if (r() < 0.12) {
                            x += 2;
                            continue;
                        }
                        if (x + bw > 29)
                            break;
                        const c = pick(r, books);
                        R(c, x, base - bh, bw, bh);
                        R(shade(c, 0.25), x, base - bh, 1, bh);
                        R(shade(c, -0.3), x, base - bh + 2, bw, 1);
                        x += bw;
                    }
                }
                break;
            }
        case "board":
            {
                R("#7c858f", 6, 26, 2, 14);
                R("#7c858f", 40, 26, 2, 14);
                R("#5f6770", 3, 38, 7, 2);
                R("#5f6770", 38, 38, 7, 2);
                R(O, 0, 0, 48, 28);
                R("#aab3bd", 1, 1, 46, 26);
                R("#f6f8fa", 3, 3, 42, 22);
                R("#e3e8ee", 3, 23, 42, 2);
                R("#7c858f", 4, 26, 40, 2);
                R("#e05d5d", 8, 26, 4, 1);
                R("#4a90d9", 14, 26, 4, 1);
                R("#3d4451", 20, 26, 4, 1);
                break;
            }
        case "plant":
            {
                const leaf = pick(r, ["#3fa560", "#4fbf75", "#2f8f5a"]);
                R("rgba(0,0,0,0.25)", 3, 28, 10, 2);
                R(O, 3, 18, 10, 11);
                R("#c4693b", 4, 19, 8, 9);
                R("#d98250", 4, 19, 8, 2);
                R("#a8552e", 5, 26, 6, 2);
                const big = r() < 0.5;
                const leaves = big ? [[2, 4, 4, 8], [10, 3, 4, 9], [6, 0, 4, 12], [4, 8, 8, 10], [1, 10, 3, 5], [12, 9, 3, 5]] : [[4, 6, 8, 12], [2, 9, 4, 6], [10, 8, 4, 7], [6, 3, 4, 6]];
                for (const l of leaves)
                    R(O, l[0] - 1, l[1] - 1, l[2] + 2, l[3] + 2);
                for (const l of leaves)
                    R(leaf, l[0], l[1], l[2], l[3]);
                for (const l of leaves)
                    R(shade(leaf, 0.25), l[0], l[1], 1, l[3] - 2);
                R(shade(leaf, -0.25), 7, 8, 1, 10);
                break;
            }
        case "fridge":
            {
                R("rgba(0,0,0,0.25)", 1, 40, 14, 2);
                R(O, 0, 0, 16, 41);
                R("#e6ebf0", 1, 1, 14, 39);
                R("#f7f9fb", 1, 1, 14, 2);
                R("#bfc8d1", 1, 14, 14, 1);
                R("#9aa5b0", 12, 5, 1, 6);
                R("#9aa5b0", 12, 18, 1, 10);
                R("#e05d5d", 3, 20, 2, 2);
                R("#4a90d9", 6, 24, 2, 2);
                R("#f2efe8", 3, 26, 4, 3);
                R("#cdd5dd", 1, 38, 14, 2);
                break;
            }
        case "counter":
            {
                R("rgba(0,0,0,0.25)", 1, 38, 46, 2);
                R(O, 0, 14, 48, 25);
                R("#dfe4ea", 1, 15, 46, 4);
                R("#ffffff", 1, 15, 46, 1);
                R("#7a5a3c", 1, 19, 46, 19);
                R("#6a4c32", 16, 19, 1, 19);
                R("#6a4c32", 32, 19, 1, 19);
                R("#c9a37a", 12, 25, 2, 4);
                R("#c9a37a", 18, 25, 2, 4);
                R("#c9a37a", 44, 25, 2, 4);
                // The coffee machine, a mug and a kettle, the sink.
                R(O, 2, 1, 12, 15);
                R("#2f2b31", 3, 2, 10, 13);
                R("#47414a", 3, 2, 10, 2);
                R("#141216", 5, 7, 6, 5);
                R("#e04848", 11, 4, 1, 1);
                R("#5fd38a", 9, 4, 1, 1);
                R("#f4f4f4", 6, 10, 4, 3);
                R("#6b4226", 6, 10, 4, 1);
                R(O, 18, 9, 5, 6);
                R("#e8894a", 19, 10, 3, 4);
                R(O, 24, 6, 7, 9);
                R("#d0d6dd", 25, 7, 5, 7);
                R("#2f2b31", 26, 6, 3, 1);
                R("#9aa5b0", 34, 16, 12, 2);
                R("#7c8794", 35, 16, 10, 1);
                R(O, 39, 8, 3, 8);
                R("#c8d0d8", 40, 9, 1, 7);
                R("#c8d0d8", 38, 9, 3, 1);
                break;
            }
        case "cooler":
            {
                R("rgba(0,0,0,0.25)", 2, 32, 12, 2);
                R(O, 3, 0, 10, 12);
                R("#8ec5ff", 4, 1, 8, 10);
                R("#c4e1ff", 5, 2, 2, 7);
                R("#4a90d9", 6, 0, 4, 1);
                R(O, 2, 11, 12, 22);
                R("#eef1f4", 3, 12, 10, 20);
                R("#d5dbe1", 3, 28, 10, 4);
                R("#4a90d9", 5, 16, 2, 2);
                R("#e05d5d", 9, 16, 2, 2);
                R("#bfc8d1", 4, 21, 8, 1);
                break;
            }
        case "vending":
            {
                R("rgba(0,0,0,0.25)", 1, 42, 30, 2);
                R(O, 0, 0, 32, 43);
                R("#c8374a", 1, 1, 30, 41);
                R("#e05d6d", 1, 1, 30, 2);
                R("#1e1a24", 3, 5, 18, 30);
                const snacks = ["#e8c14a", "#4a90d9", "#7cc06a", "#e8894a", "#f2efe8", "#d36ba6"];
                for (let row = 0; row < 4; row++) {
                    R("#3a3542", 3, 11 + row * 7, 18, 1);
                    for (let col = 0; col < 4; col++)
                        R(pick(r, snacks), 4 + col * 4, 7 + row * 7, 3, 4);
                }
                R("rgba(255,255,255,0.18)", 4, 6, 2, 28);
                R("#2b2f39", 23, 6, 6, 10);
                R("#5fd38a", 24, 7, 4, 2);
                for (let i = 0; i < 3; i++)
                    R("#d7dbe2", 24, 11 + i * 2, 4, 1);
                R("#1e1a24", 4, 37, 16, 3);
                break;
            }
        case "arcade":
            {
                R("rgba(0,0,0,0.25)", 1, 40, 14, 2);
                R(O, 0, 0, 16, 41);
                R("#5b3c8f", 1, 1, 14, 39);
                R("#f8c25c", 2, 2, 12, 5);
                R("#e05d5d", 4, 3, 8, 3);
                R("#1e1a24", 2, 9, 12, 11);
                R("#2fd1c4", 3, 10, 10, 9);
                R("#f8c25c", 5, 12, 2, 2);
                R("#e05d5d", 9, 15, 2, 2);
                R("#ffffff", 7, 17, 1, 1);
                R("#3d2a63", 1, 21, 14, 5);
                R("#e04848", 4, 21, 2, 2);
                R("#2b2f39", 4, 23, 2, 2);
                R("#5fd38a", 9, 22, 2, 2);
                R("#f8c25c", 12, 22, 2, 2);
                R("#4a3275", 1, 26, 14, 14);
                R("#2fd1c4", 6, 30, 4, 1);
                break;
            }
        case "table":
            {
                R("rgba(0,0,0,0.25)", 4, 27, 24, 4);
                const rows = [[10, 22], [6, 26], [4, 28], [3, 29], [2, 30], [2, 30], [2, 30], [2, 30], [2, 30], [3, 29], [4, 28], [6, 26], [10, 22]];
                rows.forEach((row, i) => R(O, row[0] - 1, 4 + i, row[1] - row[0] + 2, 1));
                R(O, 9, 3, 14, 1);
                R(O, 9, 17, 14, 1);
                rows.forEach((row, i) => R(i < 2 ? "#d9a46c" : "#c48d55", row[0], 4 + i, row[1] - row[0], 1));
                R("#9c6b3c", 3, 14, 26, 2);
                R(O, 14, 18, 4, 9);
                R("#7a5530", 15, 18, 2, 9);
                R("#7a5530", 10, 26, 12, 2);
                R(O, 12, 6, 4, 4);
                R("#f4f4f4", 13, 7, 2, 2);
                R("#3fa560", 19, 6, 3, 2);
                R("#e05d5d", 20, 5, 1, 1);
                break;
            }
        case "stool":
            {
                const wood = "#a87444", seat = "#c48d55";
                if (p.face === 0) {
                    R(O, 3, 0, 10, 14);
                    R(wood, 4, 1, 8, 5);
                    R(seat, 4, 7, 8, 5);
                    R(wood, 4, 12, 1, 2);
                    R(wood, 11, 12, 1, 2);
                } else if (p.face === 3) {
                    R(wood, 4, 13, 1, 2);
                    R(wood, 11, 13, 1, 2);
                    R(O, 3, 8, 10, 6);
                    R(wood, 4, 9, 8, 4);
                } else {
                    const left = p.face === 1;
                    R(O, 3, 5, 10, 10);
                    R(seat, 4, 6, 8, 6);
                    R(wood, 4, 12, 8, 2);
                    R(O, left ? 11 : 2, 0, 3, 13);
                    R(wood, left ? 12 : 3, 1, 1, 11);
                }
                break;
            }
        case "couch":
            {
                const c = "#3f8a8a", light = "#5aa8a8", deep = "#2c6868";
                R("rgba(0,0,0,0.25)", 2, 24, 44, 2);
                R(O, 1, 0, 46, 25);
                R(c, 2, 1, 44, 10);
                R(light, 2, 1, 44, 2);
                R(deep, 2, 10, 44, 1);
                for (let i = 0; i < 3; i++) {
                    R(light, 5 + i * 13, 11, 12, 7);
                    R(shade(light, 0.15), 5 + i * 13, 11, 12, 1);
                }
                R(deep, 2, 18, 44, 5);
                R(c, 1, 5, 5, 18);
                R(c, 42, 5, 5, 18);
                R(light, 1, 5, 5, 2);
                R(light, 42, 5, 5, 2);
                R("#e8c14a", 8, 5, 6, 5);
                R("#f2efe8", 34, 5, 5, 5);
                R("#5a4033", 3, 23, 2, 2);
                R("#5a4033", 43, 23, 2, 2);
                break;
            }
        case "coffeeTable":
            {
                R("rgba(0,0,0,0.25)", 2, 14, 28, 2);
                R(O, 1, 3, 30, 11);
                R("#8f6538", 2, 4, 28, 6);
                R("#a87444", 2, 4, 28, 1);
                R("#6a4c32", 2, 10, 28, 3);
                R("#4a90d9", 5, 5, 7, 4);
                R("#f2efe8", 6, 6, 5, 1);
                R("#f4f4f4", 21, 5, 3, 3);
                R("#6b4226", 21, 5, 3, 1);
                break;
            }
        case "armchair":
            {
                const c = "#b5654a", light = "#cf8064";
                R("rgba(0,0,0,0.25)", 2, 20, 13, 2);
                R(O, 1, 4, 15, 17);
                R(c, 10, 5, 5, 15);
                R(light, 10, 5, 5, 1);
                R(light, 2, 10, 9, 6);
                R(c, 2, 5, 9, 4);
                R(shade(c, -0.2), 2, 16, 13, 4);
                R(light, 2, 5, 9, 1);
                break;
            }
        case "petBed":
            {
                R("rgba(0,0,0,0.2)", 1, 11, 14, 2);
                R(O, 1, 4, 14, 9);
                R("#c0392b", 2, 5, 12, 7);
                R("#e05d5d", 2, 5, 12, 1);
                R("#f2d6c4", 4, 7, 8, 4);
                R("#e8c4ae", 4, 10, 8, 1);
                break;
            }
        }
    }

    // ── The page ────────────────────────────────────────────────────────────

    ListModel {
        id: actorModel
    }

    ListModel {
        id: moverModel
    }

    Timer {
        objectName: "officeSheetPainter"
        interval: 16
        repeat: true
        running: page.visible && page.sheetsPending > 0
        onTriggered: page.paintSheets()
    }

    Timer {
        interval: page.walking ? 40 : 200
        repeat: true
        running: page.animating
        onTriggered: page.tick(interval)
    }

    // The sky in the windows and the clock follow the time of day.
    Timer {
        property int hour: new Date().getHours()

        interval: 60000
        repeat: true
        running: page.animating
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
                enabled: page.pixelScale > page.minScale + 0.001
                onClicked: page.zoomBy(1 / 1.25)
            }

            ShellButton {
                text: qsTr("Fit")
                toolTip: qsTr("Fit the office to the view")
                enabled: page.zoom !== 1
                onClicked: page.zoom = 1
            }

            ShellButton {
                objectName: "officeZoomIn"
                text: "+"
                toolTip: qsTr("Zoom in")
                enabled: page.pixelScale < page.topScale - 0.001
                onClicked: page.zoomBy(1.25)
            }
        }

        Flickable {
            id: scroller

            objectName: "officeScroller"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: Math.max(width, stage.width)
            contentHeight: Math.max(height, stage.height)
            boundsBehavior: Flickable.StopAtBounds

            ScrollBar.vertical: ScrollBar {}
            ScrollBar.horizontal: ScrollBar {}

            Item {
                id: stage

                objectName: "officeStage"
                // Hidden until set up; the people in it are out of reach until
                // then too (see their MouseArea).
                opacity: page.settled ? 1 : 0
                x: Math.max(0, (scroller.width - width) / 2)
                y: Math.max(0, (scroller.height - height) / 2)
                width: page.worldCols * 16 * page.pixelScale
                height: page.worldRows * 16 * page.pixelScale

                Item {
                    objectName: "officeArt"
                    width: page.worldCols * 16 * page.drawScale
                    height: page.worldRows * 16 * page.drawScale
                    scale: page.pixelScale / page.drawScale
                    transformOrigin: Item.TopLeft
                    layer.enabled: page.resampled
                    layer.smooth: true

                    Item {
                        id: world

                        width: page.worldCols * 16
                        height: page.worldRows * 16
                        scale: page.drawScale
                        transformOrigin: Item.TopLeft

                        Canvas {
                            id: floor

                            z: -1
                            width: Math.max(1, page.worldCols * 16)
                            height: Math.max(1, page.worldRows * 16)
                            smooth: false
                            antialiasing: false
                            onPaint: {
                                page.floorPaints++;
                                page.paintFloor(getContext("2d"));
                                page.settle(page.office);
                            }
                        }

                        Repeater {
                            model: page.props

                            delegate: Canvas {
                                required property var modelData

                                x: modelData.x
                                y: modelData.y
                                z: modelData.z
                                width: modelData.w
                                height: modelData.h
                                smooth: false
                                antialiasing: false
                                onPaint: page.paintProp(getContext("2d"), modelData)
                            }
                        }

                        // Each seat's desk and chair, shown while it is in the office.
                        Repeater {
                            model: page.units

                            delegate: Canvas {
                                id: unit

                                required property var modelData

                                x: modelData.x
                                y: modelData.y
                                z: modelData.z
                                width: modelData.w
                                height: modelData.h
                                smooth: false
                                antialiasing: false
                                Component.onCompleted: {
                                    page.unitViews[modelData.key] = unit;
                                    visible = page.deskShown(page.world.seats[modelData.seat]);
                                }
                                Component.onDestruction: {
                                    if (page.unitViews[modelData.key] === unit)
                                        delete page.unitViews[modelData.key];
                                }
                                onPaint: page.paintProp(getContext("2d"), modelData)
                            }
                        }

                        // The screens of the computers facing us.
                        Repeater {
                            model: page.screens

                            delegate: Rectangle {
                                id: screen

                                required property var modelData
                                property string mode: "off"
                                property real phase: 0
                                readonly property bool code: mode === "typing" || mode === "thinking" || mode === "delegating" || mode === "planning" || mode === "reading"
                                readonly property bool terminal: mode === "running" || mode === "testing"

                                x: modelData.x
                                y: modelData.y
                                z: modelData.z
                                width: 8
                                height: 6
                                color: mode === "off" ? "#141a24" : mode === "failed" ? "#7a1f2b" : mode === "browsing" ? "#f2f4f8" : terminal ? "#0d1210" : mode === "idle" ? "#24406a" : "#1d2a44"
                                Component.onCompleted: {
                                    page.screenViews[modelData.key] = screen;
                                    visible = page.deskShown(page.world.seats[modelData.seat]);
                                }
                                Component.onDestruction: {
                                    if (page.screenViews[modelData.key] === screen)
                                        delete page.screenViews[modelData.key];
                                }

                                Repeater {
                                    model: 3

                                    delegate: Rectangle {
                                        required property int index

                                        visible: screen.mode !== "off"
                                        x: screen.mode === "browsing" ? 1 : 1 + (index === 1 ? 1 : 0)
                                        y: 1 + index * 2 - (screen.mode === "browsing" && index === 0 ? 1 : 0)
                                        height: 1
                                        width: {
                                            if (screen.mode === "failed")
                                                return index === 1 ? 6 : 0;
                                            if (screen.mode === "browsing")
                                                return index === 0 ? 8 : 2 + ((Math.floor(screen.phase) + index * 3) % 4);
                                            if (screen.mode === "idle")
                                                return index === 1 ? 2 : 0;
                                            return 1 + ((Math.floor(screen.phase) * (index + 2) + index * 5) % 6);
                                        }
                                        color: {
                                            if (screen.mode === "failed")
                                                return "#ffb3b3";
                                            if (screen.mode === "browsing")
                                                return index === 0 ? "#4a90d9" : "#9aa5b0";
                                            if (screen.mode === "testing")
                                                return (Math.floor(screen.phase) + index) % 5 === 0 ? "#ff6b6b" : "#5fd38a";
                                            if (screen.mode === "running")
                                                return "#5fd38a";
                                            if (screen.mode === "idle")
                                                return "#9cc8ff";
                                            return ["#c792ea", "#82aaff", "#f8c25c"][index];
                                        }
                                    }
                                }
                            }
                        }

                        // The project on each desk, for whoever has it.
                        Repeater {
                            model: page.deskMarks

                            delegate: Item {
                                id: mark

                                required property var modelData
                                property string kind: ""
                                property string label: ""
                                property string tint: ""
                                property string emoji: ""
                                property string url: ""
                                readonly property string sign: [kind, label, tint, emoji].join("\n")

                                objectName: "officeDeskMark"
                                x: modelData.x
                                y: modelData.y
                                z: modelData.z
                                width: modelData.w
                                height: modelData.h
                                visible: false
                                onSignChanged: tile.requestPaint()
                                Component.onCompleted: {
                                    page.markViews[modelData.key] = mark;
                                    page.updateMark(modelData);
                                }
                                Component.onDestruction: {
                                    if (page.markViews[modelData.key] === mark)
                                        delete page.markViews[modelData.key];
                                }

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
                                Component.onCompleted: page.boardViews[modelData.key] = board
                                Component.onDestruction: {
                                    if (page.boardViews[modelData.key] === board)
                                        delete page.boardViews[modelData.key];
                                }

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
                        Repeater {
                            model: moverModel

                            delegate: Item {
                                id: mover

                                required property string moverId
                                property int frame: 0
                                property int dir: 0
                                property bool carrying: false
                                readonly property var who: page.movers[moverId] ?? null

                                objectName: "officeMover:" + moverId
                                width: 16
                                height: 24
                                Component.onCompleted: {
                                    page.moverViews[moverId] = mover;
                                    if (who)
                                        page.renderMover(who);
                                }
                                Component.onDestruction: {
                                    if (page.moverViews[moverId] === mover)
                                        delete page.moverViews[moverId];
                                }

                                Item {
                                    width: 16
                                    height: 24
                                    clip: true

                                    Canvas {
                                        x: -(mover.frame + (mover.carrying ? 3 : 0)) * 18
                                        y: -mover.dir * 26
                                        width: 108
                                        height: 104
                                        smooth: false
                                        antialiasing: false
                                        onPaint: {
                                            if (mover.who)
                                                page.paintMoverSheet(getContext("2d"), mover.who.look);
                                        }
                                    }
                                }

                                Canvas {
                                    objectName: "officeLoad:" + mover.moverId
                                    visible: mover.carrying
                                    // Seen from behind, the mover's back hides it.
                                    z: mover.dir === 3 ? -1 : 0
                                    y: 8
                                    width: 16
                                    height: 14
                                    smooth: false
                                    antialiasing: false
                                    onPaint: page.paintLoad(getContext("2d"), mover.who?.chair ?? "#3d4a63")
                                }
                            }
                        }

                        // The people.
                        Repeater {
                            model: actorModel

                            delegate: Item {
                                id: person

                                required property string actorId
                                property int frame: 0
                                property int dir: 0
                                readonly property var look: page.actors[actorId]?.look ?? null
                                // Its sprite sheet: "queued", "due" (asked to
                                // paint) or "painted"; see paintSheets().
                                property string sheet: ""
                                readonly property bool paintable: sheetCanvas.available

                                function requestSheet() {
                                    sheetCanvas.requestPaint();
                                }

                                width: 16
                                height: 24
                                clip: true
                                Component.onCompleted: {
                                    page.views[actorId] = person;
                                    page.queueSheet(person);
                                    const actor = page.actors[actorId];
                                    if (actor)
                                        page.render(actor);
                                }
                                Component.onDestruction: {
                                    page.dropSheet(person);
                                    if (page.views[actorId] === person)
                                        delete page.views[actorId];
                                }

                                Canvas {
                                    id: sheetCanvas

                                    x: -person.frame * 18
                                    y: -[0, 26, 26, 52][person.dir]
                                    width: 270
                                    height: 78
                                    smooth: false
                                    antialiasing: false
                                    transform: Scale {
                                        origin.x: person.frame * 18 + 8
                                        xScale: person.dir === 2 ? -1 : 1
                                    }
                                    onPaint: {
                                        if (person.sheet === "queued")
                                            return;
                                        const start = Date.now();
                                        if (person.look)
                                            page.paintSheet(getContext("2d"), person.look);
                                        page.sheetPainted(person, Date.now() - start);
                                    }
                                }

                                // Tab walks the people; a focused one shows its card as a
                                // hovered one does, and Return or Space opens its thread.
                                // Nobody is reachable while the office is being set up.
                                // (On this item, not the stage: under a stage whose
                                // `enabled` changes, Ljós reports `visible` a change late,
                                // hal-c2/ljos-ui#611.)
                                MouseArea {
                                    id: hit

                                    enabled: page.settled

                                    objectName: "officePerson:" + person.actorId
                                    Accessible.role: Accessible.Button
                                    Accessible.name: page.people.find(p => p.id === person.actorId)?.title ?? qsTr("Person")
                                    Accessible.onPressAction: page.openPerson(person.actorId)
                                    activeFocusOnTab: true
                                    x: 2
                                    y: 2
                                    width: 12
                                    height: 21
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onEntered: page.hovered = person.actorId
                                    onExited: {
                                        if (page.hovered === person.actorId && !activeFocus)
                                            page.hovered = "";
                                    }
                                    onActiveFocusChanged: {
                                        if (activeFocus) {
                                            page.hovered = person.actorId;
                                            page.reveal(hit);
                                        } else if (page.hovered === person.actorId && !containsMouse)
                                            page.hovered = "";
                                    }
                                    onClicked: page.openPerson(person.actorId)
                                    Keys.onReturnPressed: page.openPerson(person.actorId)
                                    Keys.onEnterPressed: page.openPerson(person.actorId)
                                    Keys.onSpacePressed: page.openPerson(person.actorId)
                                }

                                // The focus ring of the person Tab is on.
                                Rectangle {
                                    visible: hit.activeFocus
                                    anchors.fill: hit
                                    color: "transparent"
                                    border.width: 1
                                    border.color: "#ffd84a"
                                }
                            }
                        }
                    }
                }

                // Speech bubbles and icons, over everything and not pixelated.
                Item {
                    id: overlay

                    anchors.fill: parent

                    Repeater {
                        model: actorModel

                        delegate: Item {
                            id: over

                            required property string actorId
                            property real anchorX: 0
                            property real anchorY: 0
                            property string icon: ""
                            property string bubble: ""
                            property int bob: 0

                            x: anchorX * page.pixelScale
                            y: anchorY * page.pixelScale
                            z: bubble ? 2 : 1
                            Component.onCompleted: {
                                page.overlays[actorId] = over;
                                const actor = page.actors[actorId];
                                if (actor)
                                    page.render(actor);
                            }
                            Component.onDestruction: {
                                if (page.overlays[actorId] === over)
                                    delete page.overlays[actorId];
                            }

                            Item {
                                objectName: "officeIcon:" + over.actorId
                                visible: over.icon !== ""
                                x: -5 * page.pixelScale
                                y: (-11 - over.bob) * page.pixelScale
                                width: 10 * page.drawScale
                                height: 11 * page.drawScale
                                scale: page.pixelScale / page.drawScale
                                transformOrigin: Item.TopLeft
                                layer.enabled: visible && page.resampled
                                layer.smooth: true

                                Item {
                                    width: 10
                                    height: 11
                                    scale: page.drawScale
                                    transformOrigin: Item.TopLeft
                                    clip: true

                                    Canvas {
                                        x: -({
                                                ask: 0,
                                                fail: 16,
                                                think: 32,
                                                nap: 48
                                            }[over.icon] ?? 0)
                                        width: 64
                                        height: 11
                                        smooth: false
                                        antialiasing: false
                                        onPaint: page.paintIcons(getContext("2d"))
                                    }
                                }
                            }

                            Rectangle {
                                id: bubble

                                objectName: "officeBubble:" + over.actorId
                                visible: over.bubble !== ""
                                x: Math.max(-over.x, Math.min(stage.width - over.x - width, -width / 2))
                                y: -height - 3 * page.pixelScale
                                width: Math.min(220, bubbleText.implicitWidth + 16)
                                height: bubbleText.implicitHeight + 10
                                color: "#fbf8f1"
                                border.color: "#211d2a"
                                border.width: 2

                                Text {
                                    id: bubbleText

                                    anchors.centerIn: parent
                                    width: Math.min(204, implicitWidth)
                                    text: over.bubble
                                    textFormat: Text.PlainText
                                    color: "#211d2a"
                                    wrapMode: Text.Wrap
                                    maximumLineCount: 3
                                    elide: Text.ElideRight
                                    font.pixelSize: Math.round(12 * Theme.fontScale)
                                    font.weight: Font.Medium
                                }

                                Rectangle {
                                    x: -bubble.x - 4
                                    y: bubble.height - 2
                                    width: 8
                                    height: 4
                                    color: "#fbf8f1"
                                    border.color: "#211d2a"
                                    border.width: 2
                                }

                                Rectangle {
                                    x: -bubble.x - 2
                                    y: bubble.height - 2
                                    width: 4
                                    height: 3
                                    color: "#fbf8f1"
                                }
                            }
                        }
                    }

                    // Who the hovered person is.
                    Rectangle {
                        id: card

                        readonly property var actor: page.hovered ? page.actors[page.hovered] ?? null : null
                        readonly property var person: page.people.find(p => p.id === page.hovered) ?? null
                        readonly property var over: page.hovered ? page.overlays[page.hovered] ?? null : null

                        objectName: "officeCard"
                        visible: person !== null && over !== null
                        z: 10
                        x: over ? Math.max(0, Math.min(stage.width - width, over.x + 10 * page.pixelScale)) : 0
                        y: over ? Math.max(0, over.y - 4 * page.pixelScale) : 0
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

            Text {
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
        }
    }

    // Scrolls the office just enough to show `item`.
    function reveal(item) {
        const r = item.mapToItem(scroller.contentItem, 0, 0, item.width, item.height);
        const fit = (at, size, view, content, start) => {
            let next = at;
            if (start < next)
                next = start;
            else if (start + size > next + view)
                next = start + size - view;
            return Math.max(0, Math.min(Math.max(0, content - view), next));
        };
        scroller.contentX = fit(scroller.contentX, r.width, scroller.width, scroller.contentWidth, r.x);
        scroller.contentY = fit(scroller.contentY, r.height, scroller.height, scroller.contentHeight, r.y);
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
