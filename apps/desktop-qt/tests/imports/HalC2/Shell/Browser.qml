pragma Singleton
import QtQuick

// The in-app browser (src/native/Browser.h) as the QML tests see it: no
// shared profile (pages use the engine's off-the-record default).
QtObject {
    readonly property var profile: null
    property string devToolsDock: "bottom"
    property real devToolsShare: 0.4
    property bool devicesView: false
    property var devicesPresetIds: []
    property bool devices3d: false
}
