pragma Singleton
import QtQuick

// Stands in for RightPanelController (desktop-qt/src/native/RightPanelController.h); its models are empty.
QtObject {
    readonly property var diff: null
    readonly property var files: null
    readonly property var review: null
    readonly property var pullRequests: null
    readonly property var previews: null
    readonly property var device: null
    readonly property var agents: null
}
