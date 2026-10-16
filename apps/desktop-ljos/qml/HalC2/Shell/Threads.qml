pragma Singleton
import QtQuick

// Stands in for ThreadStore (desktop-qt/src/native/ThreadStore.h).
QtObject {
    readonly property string activeThread: ""
    readonly property var timeline: null
    function reload(threadKey) {}
}
