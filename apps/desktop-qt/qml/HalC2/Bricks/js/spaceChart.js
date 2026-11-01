.pragma library

// A chart block's arithmetic: where its marks go, in a plot of the given size.
// Everything here reads the chart as data; nothing in it is ever interpreted.

// The largest value of any series.
function peak(chart) {
    let most = 0;
    for (const series of chart.series ?? []) {
        for (let i = 0; i < series.values.length; ++i)
            most = Math.max(most, series.values[i]);
    }
    return most;
}

// An axis tick: 1200 reads 1.2K, so the longest fits beside the plot.
function compact(value) {
    const units = [[1e12, "T"], [1e9, "B"], [1e6, "M"], [1e3, "K"]];
    for (const [size, unit] of units) {
        if (value >= size)
            return String(Math.round(value / size * 10) / 10) + unit;
    }
    return String(Math.round(value * 100) / 100);
}

// Grouped bars from the baseline: one group per label, one thin bar per series
// with 2px between them. A value above zero always shows.
function bars(chart, max, width, height) {
    const count = chart.labels?.length ?? 0;
    const groups = chart.series?.length ?? 0;
    if (count === 0 || groups === 0 || max <= 0 || width <= 0)
        return [];
    const band = width / count;
    const gap = 2;
    const thick = Math.max(1, Math.min(32, (band * 0.7 - gap * (groups - 1)) / groups));
    const span = thick * groups + gap * (groups - 1);
    const out = [];
    for (let s = 0; s < groups; ++s) {
        for (let i = 0; i < count; ++i) {
            const value = chart.series[s].values[i];
            const tall = value > 0 ? Math.max(2, value / max * height) : 0;
            out.push({
                series: s,
                x: band * i + (band - span) / 2 + s * (thick + gap),
                y: height - tall,
                width: thick,
                height: tall
            });
        }
    }
    return out;
}

// Where a line chart's label `i` of `count` sits; 6px in, so a marker fits.
function pointX(i, count, width) {
    return count < 2 ? width / 2 : 6 + i / (count - 1) * (width - 12);
}

// One straight path per series, and its points. A line joins only what was
// counted, so it is never smoothed past a value.
function lines(chart, max, width, height) {
    const count = chart.labels?.length ?? 0;
    if (count === 0 || max <= 0 || width <= 0)
        return [];
    const out = [];
    for (let s = 0; s < (chart.series?.length ?? 0); ++s) {
        const points = [];
        let path = "";
        for (let i = 0; i < count; ++i) {
            const x = pointX(i, count, width);
            const y = height - chart.series[s].values[i] / max * height;
            points.push({ series: s, x: x, y: y });
            path += (i === 0 ? "M " : " L ") + x + " " + y;
        }
        out.push({ series: s, path: path, points: points });
    }
    return out;
}

// The labels under the plot, as many as fit `each` pixels apart, always from
// the first, each in a box kept inside the plot and said how to sit in it.
function ticks(chart, width, each) {
    const count = chart.labels?.length ?? 0;
    if (count === 0 || width <= 0)
        return [];
    const step = Math.max(1, Math.ceil(count * each / width));
    const band = width / count;
    const box = Math.min(width, (step === 1 ? Math.max(band, each) : each) - 4);
    const out = [];
    for (let i = 0; i < count; i += step) {
        const centre = chart.type === "line" ? pointX(i, count, width) : band * i + band / 2;
        const wanted = centre - box / 2;
        const left = Math.max(0, Math.min(width - box, wanted));
        out.push({
            text: chart.labels[i],
            x: left,
            width: box,
            align: left > wanted ? "left" : left < wanted ? "right" : "center"
        });
    }
    return out;
}

// The numbers behind the chart as a table's cells, row by row: a head of the
// series' names, then each label and its values.
function cells(chart) {
    const out = [""];
    for (const series of chart.series ?? [])
        out.push(series.name);
    for (let i = 0; i < (chart.labels?.length ?? 0); ++i) {
        out.push(chart.labels[i]);
        for (const series of chart.series)
            out.push(String(series.values[i]));
    }
    return out;
}
