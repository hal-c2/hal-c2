.pragma library

// The scheduled task editor's weekday buttons: a day turned off or on, the
// last chosen day staying chosen (a fixed-time task runs on some day).
function toggleDay(days, day) {
    const next = (days || []).slice();
    const at = next.indexOf(day);
    if (at < 0) next.push(day);
    else if (next.length > 1) next.splice(at, 1);
    return next;
}
