pragma Singleton
import QtQuick

// SettingsController's rows as state a test sets directly: `device` and
// `document` hold what is off its default, `defaults` the rest.
QtObject {
    property bool ready: true
    property var device: ({})
    property var document: ({})
    property var defaults: ({})
    property var nodeKeys: []

    function store(key) {
        return nodeKeys.indexOf(key) >= 0 ? document : device;
    }
    function setting(key) {
        const values = store(key);
        return key in values ? values[key] : defaults[key];
    }
    function isDefault(key) {
        return !(key in store(key));
    }
    function defaultOf(key) {
        return defaults[key];
    }
    function onDevice(key) {
        return nodeKeys.indexOf(key) < 0;
    }
    function set(key, value) {
        const node = nodeKeys.indexOf(key) >= 0;
        const next = Object.assign({}, node ? document : device);
        if (value === defaults[key]) delete next[key];
        else next[key] = value;
        if (node) document = next;
        else device = next;
    }
    function reset(key) {
        set(key, defaults[key]);
    }
    function clear() {
        ready = true;
        device = {};
        document = {};
        defaults = {};
        nodeKeys = [];
    }
}
