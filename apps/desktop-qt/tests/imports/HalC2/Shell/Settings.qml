pragma Singleton
import QtQuick

// SettingsController's rows as state a test sets directly: `device` and
// `document` hold what is off its default, `defaults` the rest.
QtObject {
    property bool ready: true
    property var device: ({})
    property var document: ({})
    property var defaults: ({})
    property var mcKeys: []

    function store(key) {
        return mcKeys.indexOf(key) >= 0 ? document : device;
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
        return mcKeys.indexOf(key) < 0;
    }
    function set(key, value) {
        const mc = mcKeys.indexOf(key) >= 0;
        const next = Object.assign({}, mc ? document : device);
        if (value === defaults[key]) delete next[key];
        else next[key] = value;
        if (mc) document = next;
        else device = next;
    }
    function reset(key) {
        set(key, defaults[key]);
    }
    function resetAll(keys) {
        const nextDevice = Object.assign({}, device);
        const nextDocument = Object.assign({}, document);
        for (const key of keys) {
            delete nextDevice[key];
            delete nextDocument[key];
        }
        device = nextDevice;
        document = nextDocument;
    }
    function clear() {
        ready = true;
        device = {};
        document = {};
        defaults = {};
        mcKeys = [];
    }
}
