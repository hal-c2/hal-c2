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

    function reload(threadKey) {
        reloads = reloads.concat([threadKey]);
    }
    function reset() {
        activeThread = "";
        timeline = null;
        reloads = [];
    }
}
