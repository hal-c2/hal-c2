pragma Singleton
import QtQml
import HalC2.Shell

// Times as the app shows them, for plugin pages: they follow the user's Time
// format setting (System default, 12-hour, 24-hour) and locale, with plain
// spaces. Each takes a Date, an ISO 8601 string or milliseconds since the
// epoch, and gives "" for a missing or invalid time. A binding that calls one
// is evaluated again when the setting changes, since each reads
// Threads.timestampFormat, which notifies on a format or locale change.
//   Format.time(at)      "18:05", "6:05 PM"
//   Format.date(at)      "9/20", or "9/20/2025" in another year
//   Format.dateTime(at)  "9/20 18:05"
//   Format.relative(at)  "just now", "5m ago", "in 2h", "3d ago"; moves on
//                        once a minute.
QtObject {
    // Counts minutes, so a binding that calls relative() is evaluated again
    // once a minute: one timer for every page, instead of one each.
    property int minute: 0
    property Timer ticker: Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: minute++
    }

    function at(value) {
        // 0 and "" are a missing time, as they were to the pages before.
        if (!value)
            return null;
        const date = value instanceof Date ? value : new Date(value);
        return isNaN(date.getTime()) ? null : date;
    }
    // Read by each formatter, so a binding that calls it depends on the setting.
    function follow() {
        return Threads.timestampFormat;
    }
    function time(value) {
        const date = at(value);
        follow();
        return date ? Threads.formatTime(date) : "";
    }
    function date(value) {
        const day = at(value);
        follow();
        return day ? Threads.formatDate(day) : "";
    }
    function dateTime(value) {
        const date = at(value);
        follow();
        return date ? Threads.formatDateTime(date) : "";
    }
    function relative(value) {
        const date = at(value);
        minute;
        return date ? Threads.formatRelative(date) : "";
    }
}
