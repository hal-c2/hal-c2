.pragma library

// The usage chart's arithmetic, as the web's UsageProviderChart.tsx does it.

// A scale whose maximum is a readable 1/2/5 x 10^n step at or above `peak`,
// so the tallest period is never drawn past the top of the plot.
function niceScale(peak, count) {
    if (!(peak > 0))
        return { max: 0, ticks: [0] };
    const rawStep = peak / count;
    const magnitude = Math.pow(10, Math.floor(Math.log10(rawStep)));
    const normalized = rawStep / magnitude;
    const step = (normalized > 5 ? 10 : normalized > 2 ? 5 : normalized > 1 ? 2 : 1) * magnitude;
    const max = Math.ceil(peak / step) * step;
    const ticks = [];
    for (let value = 0; value <= max + step * 1e-6; value += step)
        ticks.push(value);
    return { max: max, ticks: ticks };
}

// Shape-preserving cubic tangents that cannot overshoot spiky usage.
function monotoneTangents(points) {
    const count = points.length;
    const slopes = [];
    for (let i = 0; i < count - 1; ++i) {
        const dx = points[i + 1].x - points[i].x;
        slopes.push(dx === 0 ? 0 : (points[i + 1].y - points[i].y) / dx);
    }
    const tangents = [slopes[0]];
    for (let i = 1; i < count - 1; ++i)
        tangents.push(slopes[i - 1] * slopes[i] <= 0 ? 0 : (slopes[i - 1] + slopes[i]) / 2);
    tangents.push(slopes[count - 2]);
    for (let i = 0; i < count - 1; ++i) {
        if (slopes[i] === 0) {
            tangents[i] = 0;
            tangents[i + 1] = 0;
            continue;
        }
        const a = tangents[i] / slopes[i];
        const b = tangents[i + 1] / slopes[i];
        const magnitude = a * a + b * b;
        if (magnitude > 9) {
            const scale = 3 / Math.sqrt(magnitude);
            tangents[i] = scale * a * slopes[i];
            tangents[i + 1] = scale * b * slopes[i];
        }
    }
    return tangents;
}

// The SVG path of a smooth line through `points` [{x, y}], left to right; ""
// for fewer than two.
function smoothPath(points) {
    if (points.length < 2)
        return "";
    const tangents = monotoneTangents(points);
    let path = "M" + points[0].x.toFixed(2) + "," + points[0].y.toFixed(2);
    for (let i = 0; i < points.length - 1; ++i) {
        const from = points[i];
        const to = points[i + 1];
        const third = (to.x - from.x) / 3;
        path += " C" + (from.x + third).toFixed(2) + "," + (from.y + tangents[i] * third).toFixed(2)
            + " " + (to.x - third).toFixed(2) + "," + (to.y - tangents[i + 1] * third).toFixed(2)
            + " " + to.x.toFixed(2) + "," + to.y.toFixed(2);
    }
    return path;
}
