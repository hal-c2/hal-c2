import QtQuick

// The effort as rising bars (upstream's EffortGlyph), Appearance's "Bars":
// one per level, 2px wide on a 4px step, from about half height up, the
// chosen level and those under it filled and the rest faint.
Item {
    id: glyph

    property int count: 0
    property int filled: 0
    property color color
    readonly property int maxBar: 12
    // Rounding each bar mixes 1px and 2px steps, so the step is rounded once.
    readonly property int rise: Math.max(1, Math.round(maxBar / 2 / Math.max(count - 1, 1)))

    width: Math.max(0, 4 * count - 2)
    height: 14

    Repeater {
        model: glyph.count

        Rectangle {
            required property int index

            x: index * 4
            y: glyph.maxBar - height
            width: 2
            height: glyph.maxBar - (glyph.count - 1 - index) * glyph.rise
            color: glyph.color
            opacity: index < glyph.filled ? 1 : 0.4
        }
    }
}
