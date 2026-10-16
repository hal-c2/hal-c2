pragma Singleton
import QtQuick

// Stands in for ShellBridge (desktop-qt/src/ShellBridge.cpp): no controllers, so every key is empty.
QtObject {
    readonly property int protocolVersion: 1
    readonly property bool localFolderImportEnabled: false
    // ShellBridge's kStateKeys; a binding reading another key sees undefined.
    readonly property QtObject state: QtObject {
        readonly property var backendError: null
        readonly property var composer: null
        readonly property var git: null
        readonly property var layout: null
        readonly property var modelPicker: null
        readonly property var sidebar: null
        readonly property var theme: null
        readonly property var workspace: null
    }
    signal windowCommandRequested(string command)
    signal actionRequested(string action, var payload)
    signal stateEntryChanged(string key, var value)
    function dispatch(action, payload) {}
    function publish(key, value) {}
    function openExternal(url) {}
    function windowCommand(command) { windowCommandRequested(command); }
    function localDirectoryPath(url) { return ""; }
    function readImageFiles(urls) { return []; }
    function readAttachmentFiles(urls) { return []; }
    function directoryPaths(urls) { return []; }
    function clipboardText() { return ""; }
    function setClipboardText(text) {}
    function clipboardFiles() { return []; }
    function pasteAttaches(text, promptLength) { return false; }
}
