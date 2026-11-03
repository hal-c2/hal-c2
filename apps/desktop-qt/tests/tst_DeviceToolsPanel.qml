import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

// hal-c2#923: the tools drawer must stay usable as a narrow side panel or a
// 2x2 stage pane shrinks it, down to ~320px wide.
TestCase {
    id: testCase
    name: "DeviceToolsPanelTests"
    width: 600
    height: 700
    when: windowShown

    QtObject {
        id: fakeSettings
        property string appearance: "dark"
        property string textSize: "default"
        property string liquidGlass: "clear"
        property string colorFilter: "none"
        property bool reduceMotion: false
        property bool increaseContrast: false
        property bool reduceTransparency: false
        property bool showBorders: false
        property bool voiceOver: false
        property bool networkEnabled: true
    }

    QtObject {
        id: fakeView
        property bool open: true
        property bool pending: false
        property bool loaded: true
        property string error: ""
        property string platform: "ios"
        property string foreground: "com.example.app"
        property bool hasForeground: true
        property bool canRelaunch: true
        property bool axOverlay: false
        property bool axOffered: true
        property var axElements: []
        property bool eventLogOffered: true
        property bool eventLogOpen: false
        property var events: []
        property string latitude: ""
        property string longitude: ""
        property var settings: fakeSettings
    }

    QtObject {
        id: fakeTools
        property var view: fakeView

        function setOpen(open) {}
        function setSwitch(setting, checked) {}
        function choose(control, label) {}
        function submit(field, text) {}
        function setAxOverlay(on) {}
        function setLocationText(lat, lon) {}
        function applyPreset(name) {}
        function applyLocation() {}
        function clearLocation() {}
        function decide(app, permission, action) {}
        function sendPush(text) {}
        function setEventLogOpen(open) {}
        function terminate() {}
        function relaunch() {}
    }

    Component {
        id: panelComponent
        DeviceToolsPanel {
            height: 700
            tools: fakeTools
        }
    }

    function cleanup() {
        Theme.colors = {};
    }

    function findAll(item, predicate, out) {
        if (predicate(item))
            out.push(item);
        for (const child of item.children)
            findAll(child, predicate, out);
        return out;
    }

    function findOne(item, objectName) {
        const hits = findAll(item, child => child.objectName === objectName, []);
        return hits.length > 0 ? hits[0] : null;
    }

    // The window-relative rectangle of a visible, non-empty item.
    function globalRect(item) {
        const topLeft = item.mapToItem(null, 0, 0);
        return Qt.rect(topLeft.x, topLeft.y, item.width, item.height);
    }

    function intersects(a, b) {
        return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;
    }

    // Every leaf control the drawer names, so a regression anywhere shows up
    // as an overlap rather than needing one assertion per row.
    function controlRects(panel) {
        const items = findAll(panel, child => child.objectName.length > 0 && child.objectName.indexOf("tools") === 0 && child.visible && child.width > 0 && child.height > 0, []);
        return items.map(item => ({
                    name: item.objectName,
                    rect: globalRect(item)
                }));
    }

    // Column/Flickable layout repositions on the next polish pass, not
    // synchronously with the property write that triggered it. Also force
    // the TestCase's own root item visible: QQuickItem.visible is effective
    // (false if any ancestor is invisible), the TestCase's root item never
    // actually gets shown under the offscreen platform otherwise, and the
    // drawer has rows whose own height depends on reading back their own
    // `visible` — correct once the ancestor chain is genuinely visible, as
    // it is in the real running app.
    function settle(panel) {
        testCase.visible = true;
        tryVerify(() => findOne(panel, "toolsField-url") !== null && findOne(panel, "toolsField-url").width > 0);
        wait(50);
    }

    function verifyNoOverlaps(panel) {
        const entries = controlRects(panel);
        verify(entries.length > 10, "expected many tools controls, found " + entries.length);
        for (let i = 0; i < entries.length; ++i) {
            for (let j = i + 1; j < entries.length; ++j) {
                verify(!intersects(entries[i].rect, entries[j].rect), entries[i].name + " overlaps " + entries[j].name + " (" + JSON.stringify(entries[i].rect) + " vs " + JSON.stringify(entries[j].rect) + ")");
            }
        }
    }

    function test_atThreeTwentyPixelsNoControlsOverlap() {
        const panel = createTemporaryObject(panelComponent, testCase, {
            width: 320
        });
        verify(panel);
        settle(panel);
        verifyNoOverlaps(panel);
    }

    function test_atFourEightyPixelsNoControlsOverlap() {
        const panel = createTemporaryObject(panelComponent, testCase, {
            width: 480
        });
        verify(panel);
        settle(panel);
        verifyNoOverlaps(panel);
    }

    // The URL/launch fields used to live in the row's 55%-wide control
    // column; they must now span the full row.
    function test_submitFieldsSpanTheFullRowAtThreeTwentyPixels() {
        const panel = createTemporaryObject(panelComponent, testCase, {
            width: 320
        });
        settle(panel);
        const urlField = findOne(panel, "toolsField-url");
        const launchField = findOne(panel, "toolsField-launch");
        verify(urlField);
        verify(launchField);
        verify(urlField.width > panel.width * 0.7, "url field width " + urlField.width + " at panel width " + panel.width);
        verify(launchField.width > panel.width * 0.7, "launch field width " + launchField.width + " at panel width " + panel.width);
        // The submit button sits below the field, not squeezed beside it.
        // Compare window-mapped rects: the button lives in a wrapper Item
        // below the field, so its local `y` isn't in the field's space.
        const fieldRect = globalRect(urlField);
        const submitRect = globalRect(findOne(panel, "toolsSubmit-url"));
        verify(submitRect.y >= fieldRect.y + fieldRect.height, "submit y " + submitRect.y + " field bottom " + (fieldRect.y + fieldRect.height));
    }

    // The permission picker must never run under the Grant/Revoke/Reset row.
    function test_permissionPickerNeverOverlapsItsButtonsAtThreeTwentyPixels() {
        const panel = createTemporaryObject(panelComponent, testCase, {
            width: 320
        });
        settle(panel);
        const picker = findOne(panel, "toolsPermission");
        const grant = findOne(panel, "toolsPermissionGrant");
        verify(picker);
        verify(grant);
        const pickerRect = globalRect(picker);
        const grantRect = globalRect(grant);
        verify(pickerRect.x + pickerRect.width <= grantRect.x + 1, "permission picker (right edge " + (pickerRect.x + pickerRect.width) + ") overlaps Grant (left edge " + grantRect.x + ")");
    }

    // The location preset picker, Set and Clear never overlap either.
    function test_locationControlsNeverOverlapAtThreeTwentyPixels() {
        const panel = createTemporaryObject(panelComponent, testCase, {
            width: 320
        });
        settle(panel);
        const preset = globalRect(findOne(panel, "toolsLocationPreset"));
        const set = globalRect(findOne(panel, "toolsLocationSet"));
        const clear = globalRect(findOne(panel, "toolsLocationClear"));
        verify(preset.x + preset.width <= set.x + 1, "preset/set " + JSON.stringify(preset) + " " + JSON.stringify(set));
        verify(set.x + set.width <= clear.x + 1, "set/clear " + JSON.stringify(set) + " " + JSON.stringify(clear));
    }
}
