pragma Singleton
import QtQuick

// The open threads (ThreadStore), as state a test sets directly: the active
// thread's timeline is whatever model the test gives it, and retries and
// reverts are recorded. The native layout tests register this file too
// (qmlRegisterSingletonType).
QtObject {
    property string activeThread: ""
    property var timeline: null
    property var reloads: []
    property var reverts: []

    function reload(threadKey) {
        reloads = reloads.concat([threadKey]);
    }
    function revert(threadKey, rowId, restoreFiles) {
        reverts = reverts.concat([{ threadKey: threadKey, rowId: rowId, restoreFiles: restoreFiles }]);
        return true;
    }
    function reset() {
        activeThread = "";
        timeline = null;
        reloads = [];
        reverts = [];
    }
}
