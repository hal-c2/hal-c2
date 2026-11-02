pragma Singleton
import QtQuick

// The in-app browser (src/native/Browser.h) in a build without QtWebEngine:
// tests open pages in the system browser.
QtObject {
    readonly property bool supported: false
    readonly property var profile: null
    property string devToolsDock: "bottom"
    property real devToolsShare: 0.4
    property bool devicesView: false
    property var devicesPresetIds: []
    property bool devices3d: false
}
