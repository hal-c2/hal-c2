pragma Singleton
import QtQuick

// The right panel's controller (RightPanelController) without its bodies:
// tests that want a Diff, Files or Agents tab give the brick its own `source`.
QtObject {
    property var diff: null
    property var files: null
    property var agents: null
}
