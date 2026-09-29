pragma Singleton
import QtQuick

// The right panel's controller (RightPanelController) without its bodies:
// tests that want a Diff, Files, Agents, Pull requests or Previews tab give the brick its own `source`.
QtObject {
    property var diff: null
    property var files: null
    property var agents: null
    property var pullRequests: null
    property var previews: null
}
