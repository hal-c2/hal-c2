import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

Item {
    id: root
    width: 200
    height: 200

    Component {
        id: iconComponent
        ProjectIcon {
            size: 14
        }
    }

    TestCase {
        name: "ProjectIconTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function luminance(c) {
            const channel = v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
            return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
        }

        function contrast(a, b) {
            const light = Math.max(luminance(a), luminance(b));
            const dark = Math.min(luminance(a), luminance(b));
            return (light + 0.05) / (dark + 0.05);
        }

        // A monogram reads against its tile at 4.5:1 or better, whatever the
        // project's colour and the theme's surface: vivid on dark (it
        // lightens), vivid on light (it deepens), grey (no hue to keep), and
        // a mid grey tile neither direction of its own hue clears.
        function test_aMonogramReadsOnAnyTile() {
            const icon = createTemporaryObject(iconComponent, root, { name: "HAL" });
            const tints = ["#ef4444", "#3b82f6", "#22c55e", "#eab308", "#a855f7", "#808080", "#000000", "#ffffff"];
            const surfaces = ["#1c1f26", "#0b0c0f", "#ffffff", "#f4f4f5", "#747474", "#808080"];
            const low = [];
            for (const t of tints) {
                for (const s of surfaces) {
                    const tint = Qt.color(t);
                    const tile = Qt.tint(Qt.color(s), Qt.alpha(tint, 0.22));
                    const ratio = contrast(icon.readableTint(tint, tile), tile);
                    if (ratio < 4.5)
                        low.push(t + " on " + s + ": " + ratio.toFixed(2));
                }
            }
            compare(low.length, 0, "every monogram reads at 4.5:1: " + low.join(", "));
        }

        // The tile drawn uses that colour: the letters on screen are the
        // readable ones, not the raw project colour.
        function test_theDrawnMonogramIsTheReadableOne() {
            const icon = createTemporaryObject(iconComponent, root, { icon: { kind: "monogram", text: "H", tint: "#ef4444" } });
            const tile = findChild(icon, "projectIconMonogram");
            const letters = findChild(icon, "projectIconMonogramText");
            verify(tile.visible, "the monogram tile shows");
            verify(contrast(letters.color, tile.color) >= 4.5, "the letters read at " + contrast(letters.color, tile.color).toFixed(2));
        }
    }
}
