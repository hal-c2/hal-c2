pragma Singleton
import QtQuick

// The right panel's controller (RightPanelController) without its bodies:
// tests that want a Diff, Files, Agents, Pull requests, Previews or Device tab give the brick its own `source`.
QtObject {
    property var diff: null
    property var files: null
    property var agents: null
    property var pullRequests: null
    property var previews: null
    property var device: null
    // XrFiles keeps the files loaded while the XR workspace shows them.
    property bool filesShownElsewhere: false

    function setFilesShownElsewhere(shown) {
        filesShownElsewhere = shown;
    }
}
