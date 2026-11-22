import QtQuick

// The Office's pictures as code: each person's look from their seed, their
// sprite cells, the icons over their heads, and the room's floor and wall.
QtObject {
    id: art

    // Whose seeded random numbers and colour arithmetic they use.
    required property var game

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
        const r = game.random(game.hash(person.id));
        if (person.parentId && r() < 0.34) {
            const cat = r() < 0.5;
            const breed = game.pick(r, cat ? art.cats : art.dogs);
            return Object.assign({
                pet: true,
                species: cat ? "cat" : "dog",
                gender: "",
                collar: game.pick(r, ["#e04848", "#3b82f6", "#22a06b", "#e8b928", "#a855f7"]),
                eye: cat ? "#7bc043" : "#2a2226"
            }, breed);
        }
        const woman = r() < 0.5;
        const style = woman ? game.pick(r, ["long", "long", "bob", "ponytail", "bun", "pigtails", "pixie", "bob", "curly", "long"]) : game.pick(r, ["short", "short", "sidepart", "spiky", "buzz", "bald", "curly", "mohawk", "long", "sidepart"]);
        const look = {
            pet: false,
            species: "human",
            gender: woman ? "woman" : "man",
            skin: game.pick(r, art.skins),
            hair: r() < 0.15 ? game.pick(r, art.funHairs) : game.pick(r, art.hairs),
            style: style,
            top: woman && r() < 0.3 ? "dress" : game.pick(r, ["tee", "tee", "collared", "tie", "hoodie", "sweater", "blazer"]),
            shirt: game.pick(r, art.cloth),
            accent: game.pick(r, art.cloth),
            pants: game.pick(r, art.pantsColors),
            shoes: game.pick(r, art.shoeColors),
            glasses: r() < 0.3,
            headphones: r() < 0.14,
            hat: r() < 0.12 ? game.pick(r, ["beanie", "cap"]) : "",
            beard: !woman && r() < 0.32 ? game.pick(r, ["beard", "moustache", "stubble"]) : "",
            earrings: woman && r() < 0.4,
            lashes: woman && r() < 0.65,
            lipstick: woman && r() < 0.35,
            bow: woman && r() < 0.15,
            lanyard: r() < 0.2,
            blush: r() < 0.5
        };
        if (look.accent === look.shirt)
            look.accent = art.cloth[(art.cloth.indexOf(look.shirt) + 5) % art.cloth.length];
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
        const skin = L.skin, skinDark = game.shade(L.skin, -0.2);
        const top = L.top;
        const white = "#f2efe8";
        const body = top === "tie" ? white : L.shirt;
        const sleeve = top === "tie" ? white : L.shirt;
        const sleeveShade = game.shade(sleeve, -0.14);
        const short = top === "tee" || top === "dress";
        const hair = L.hair, hairDark = game.shade(L.hair, -0.25);
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
                m(8, 17, 3, l2, game.shade(legColor, -0.08));
                m(5, 17 + l1, 3, 1, L.shoes);
                m(8, 17 + l2, 3, 1, L.shoes);
            } else if (f === 1) {
                m(8, 17, 3, 3, game.shade(legColor, -0.15));
                m(4, 17, 3, 3, legColor);
                m(3, 20, 4, 1, L.shoes);
                m(8, 20, 4, 1, game.shade(L.shoes, -0.1));
            } else if (f === 2) {
                m(7, 17, 3, 3, game.shade(legColor, -0.15));
                m(5, 17, 3, 3, legColor);
                m(4, 20, 4, 1, L.shoes);
                m(7, 20, 3, 1, game.shade(L.shoes, -0.1));
            } else {
                m(6, 17, 4, 3, legColor);
                m(5, 20, 5, 1, L.shoes);
            }
        } else if (side) {
            m(3, 17, 7, 2, L.pants === legColor ? legColor : game.shade(L.shirt, -0.1));
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
                o(8, 13 + dy, 1, 1, game.shade(body, -0.25));
                o(8, 15 + dy, 1, 1, game.shade(body, -0.25));
            } else if (top === "tie") {
                o(7, 11 + dy, 2, 1, game.shade(L.accent, -0.2));
                o(7, 12 + dy, 2, 4, L.accent);
            } else if (top === "hoodie") {
                o(6, 12 + dy, 1, 2, "#f4f4f4");
                o(9, 12 + dy, 1, 2, "#f4f4f4");
                o(6, 15 + dy, 4, 1, game.shade(body, -0.18));
            } else if (top === "sweater") {
                o(5, 13 + dy, 6, 1, L.accent);
            } else if (top === "blazer") {
                o(7, 11 + dy, 2, 6, L.accent);
                o(6, 11 + dy, 1, 2, game.shade(body, -0.25));
                o(9, 11 + dy, 1, 2, game.shade(body, -0.25));
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
                o(4, 11 + dy, 8, 2, game.shade(body, -0.2));
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
                const mouth = f === 13 ? "#5a2230" : L.lipstick ? "#c8324a" : game.shade(skin, -0.35);
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
                    o(4, hy + 7, f === 13 ? 2 : 1, 1, f === 13 ? "#5a2230" : L.lipstick ? "#c8324a" : game.shade(skin, -0.35));
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
                    o(5, hy + 1, 2, 1, game.shade(skin, 0.3));
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
            o(3, hy + 2, 10, 1, game.shade(L.accent, -0.2));
            o(5, hy, 1, 2, game.shade(L.accent, 0.2));
        } else if (L.hat === "cap") {
            m(3, hy - 1, 10, 3, L.accent);
            if (side)
                m(1, hy + 1, 4, 1, game.shade(L.accent, -0.2));
            else if (!back)
                m(3, hy + 2, 10, 1, game.shade(L.accent, -0.2));
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
            o(9, 20, 4, 1, game.shade(tailColor, -0.15));
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
            m(front + 2, by + 5, 2, legs - 1, game.shade(base, -0.15));
            m(hind - 2, by + 5, 2, legs - 1, game.shade(base, -0.15));
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
                m(6, 10, 4, 3, L.muzzle ? light : (L.face ?? game.shade(base, 0.12)));
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
                o(7, 12, 2, 1, game.shade(L.muzzle ? light : base, -0.4));
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
                    o(a.body[0] + 1, y, a.body[2] - 2, 1, game.shade(L.base, -0.18));
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
                o(a.mask[0] + 1, a.mask[1] + 1, a.mask[2] - 2, a.mask[3], game.shade(L.points, 0.15));
            for (const p of a.paws ?? [])
                o(p[0], p[1], p[2], p[3], L.points);
        }
    }

    // Draws a whole sprite sheet into a canvas: 16×24 frames on an 18×26 grid,
    // so a scaled frame never samples the frame next to it.
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
        const O = art.outline;
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
        R(game.shade(chair, 0.18), 11, 2, 4, 1);
    }

    function personCell(look, frame, dir) {
        if (!look)
            return [];
        return look.pet ? petFrame(look, frame, dir) : humanFrame(look, frame, dir);
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
            fill(r[0] - 1, r[1] - 1, r[2] + 2, r[3] + 2, art.outline);
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
            const glyph = art.glyphs[ch];
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

    function paintFloor(ctx, w) {
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
        rect(ctx, art.outline, sx - 1, sy - 1, 32, 13);
        rect(ctx, "#2f7a55", sx, sy, 30, 11);
        rect(ctx, "#3f9a6c", sx, sy, 30, 1);
        paintLetters(ctx, art.letters("REVIEW"), sx + 4, sy + 3, "#f2efe8");
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
}
