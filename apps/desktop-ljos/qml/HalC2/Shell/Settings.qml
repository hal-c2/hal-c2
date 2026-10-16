pragma Singleton
import QtQuick

// Stands in for SettingsController (desktop-qt/src/native/SettingsController.h); every setting reads as unset.
QtObject {
    readonly property bool ready: false
    readonly property var document: ({})
    readonly property var device: ({})
    function setting(key) { return undefined; }
    function defaultOf(key) { return undefined; }
    function isDefault(key) { return true; }
    function mixed(key) { return false; }
    function disabledReason(key) { return ""; }
    function supports(capability) { return false; }
    function onDevice(key) { return false; }
    function set(key, value) {}
    function reset(key) {}
    function resetAll(keys) {}
}
