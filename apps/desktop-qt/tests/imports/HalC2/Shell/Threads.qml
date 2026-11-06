pragma Singleton
import QtQuick

// The open threads (ThreadStore), as state a test sets directly: the active
// thread's timeline is whatever model the test gives it, and retries are
// recorded. The native layout tests register this file too
// (qmlRegisterSingletonType).
QtObject {
    property string activeThread: ""
    property var timeline: null
    property var reloads: []
    // The Time format setting, and the formatters Format.qml calls, in en-US.
    property string timestampFormat: "locale"

    function formatTime(at) {
        return Qt.formatTime(at, timestampFormat === "24-hour" ? "HH:mm" : "h:mm AP");
    }
    function formatDate(at) {
        return (at.getMonth() + 1) + "/" + at.getDate();
    }
    function formatDateTime(at) {
        return formatDate(at) + " " + formatTime(at);
    }
    function formatRelative(at) {
        return "just now";
    }

    function reload(threadKey) {
        reloads = reloads.concat([threadKey]);
    }
    function reset() {
        activeThread = "";
        timeline = null;
        reloads = [];
        timestampFormat = "locale";
    }
}
