import QtQuick

// A piece of the office's furniture, drawn once.
Thing {
    id: furniture

    property string kind: ""
    property string tint: ""
    // Which way a stool faces.
    property int facing: 0
    property int seed: world ? world.hash(kind + x + "," + y) : 0

    Art {
        key: furniture.seed
        draw: (ctx, w, h) => furniture.drawn(ctx, w, h)
    }

    function drawn(ctx, w, h) {
        const r = world.random(seed);
        const R = (c, x, y, w, h) => {
            ctx.fillStyle = c;
            ctx.fillRect(x, y, w, h);
        };
        const O = "#211d2a";
        switch (kind) {
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
                R(world.pick(r, ["#e8894a", "#5a6fd6", "#f2efe8"]), 13, 5, 2, 2);
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
                    R(world.pick(r, ["#e05d5d", "#4a90d9", "#e8c14a", "#f2efe8"]), 1, 4, 1, 3);
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
                const north = kind === "chairsN";
                for (let i = 0; i < w / 16; i++) {
                    const x = i * 16;
                    if (north) {
                        R(O, x + 3, 0, 10, 13);
                        R(tint, x + 4, 1, 8, 6);
                        R(world.shade(tint, 0.18), x + 4, 1, 8, 1);
                        R(world.shade(tint, 0.1), x + 4, 8, 8, 4);
                        R("#2b2f39", x + 7, 13, 2, 2);
                    } else {
                        R("#2b2f39", x + 4, 14, 8, 1);
                        R("#2b2f39", x + 7, 12, 2, 2);
                        R(O, x + 2, 4, 11, 9);
                        R(tint, x + 3, 5, 9, 7);
                        R(world.shade(tint, 0.18), x + 3, 5, 9, 1);
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
                        const c = world.pick(r, books);
                        R(c, x, base - bh, bw, bh);
                        R(world.shade(c, 0.25), x, base - bh, 1, bh);
                        R(world.shade(c, -0.3), x, base - bh + 2, bw, 1);
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
                const leaf = world.pick(r, ["#3fa560", "#4fbf75", "#2f8f5a"]);
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
                    R(world.shade(leaf, 0.25), l[0], l[1], 1, l[3] - 2);
                R(world.shade(leaf, -0.25), 7, 8, 1, 10);
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
                        R(world.pick(r, snacks), 4 + col * 4, 7 + row * 7, 3, 4);
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
                if (facing === 0) {
                    R(O, 3, 0, 10, 14);
                    R(wood, 4, 1, 8, 5);
                    R(seat, 4, 7, 8, 5);
                    R(wood, 4, 12, 1, 2);
                    R(wood, 11, 12, 1, 2);
                } else if (facing === 3) {
                    R(wood, 4, 13, 1, 2);
                    R(wood, 11, 13, 1, 2);
                    R(O, 3, 8, 10, 6);
                    R(wood, 4, 9, 8, 4);
                } else {
                    const left = facing === 1;
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
                    R(world.shade(light, 0.15), 5 + i * 13, 11, 12, 1);
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
                R(world.shade(c, -0.2), 2, 16, 13, 4);
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
}
