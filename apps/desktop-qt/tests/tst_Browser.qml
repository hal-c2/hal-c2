import QtQuick
import QtTest
import "../qml/HalC2/Bricks/js/browser.js" as BrowserJs

// What the in-app browser decides without a page (js/browser.js): the address
// typed, the zoom ladder, why a page failed and how a device size fits.
TestCase {
    name: "Browser"

    function test_addresses_data() {
        return [
            { tag: "loopback gets http", input: "localhost:3000", url: "http://localhost:3000/" },
            { tag: "loopback ip", input: "127.0.0.1:5173/app", url: "http://127.0.0.1:5173/app" },
            { tag: "ipv6 loopback", input: "[::1]:8080", url: "http://[::1]:8080/" },
            { tag: "anything else gets https", input: "example.com", url: "https://example.com/" },
            { tag: "scheme kept", input: "http://example.com/a?b=1#c", url: "http://example.com/a?b=1#c" },
            { tag: "trimmed", input: "  localhost:3000  ", url: "http://localhost:3000/" },
            { tag: "scheme lowercased", input: "HTTPS://example.com", url: "https://example.com/" }
        ];
    }

    function test_addresses(data) {
        compare(BrowserJs.normalizeAddress(data.input).url, data.url);
    }

    function test_refusedAddresses_data() {
        return [
            { tag: "empty", input: "" },
            { tag: "blank", input: "   " },
            { tag: "file", input: "file:///etc/passwd" },
            { tag: "javascript", input: "javascript://alert(1)" },
            { tag: "spaces", input: "not an address" }
        ];
    }

    function test_refusedAddresses(data) {
        const result = BrowserJs.normalizeAddress(data.input);
        verify(result.url === undefined);
        verify(result.error.length > 0);
    }

    function test_otherSchemesAreNamed() {
        compare(BrowserJs.normalizeAddress("file:///etc/passwd").error, "Only http and https pages open here.");
        compare(BrowserJs.normalizeAddress("ftp://example.com").error, "Only http and https pages open here.");
    }

    function test_zoomSteps_data() {
        return [
            { tag: "in from 100%", from: 1.0, direction: 1, to: 1.1 },
            { tag: "out from 100%", from: 1.0, direction: -1, to: 0.9 },
            { tag: "in at the top", from: 5.0, direction: 1, to: 5.0 },
            { tag: "out at the bottom", from: 0.25, direction: -1, to: 0.25 },
            { tag: "from between steps", from: 1.37, direction: 1, to: 1.5 }
        ];
    }

    function test_zoomSteps(data) {
        compare(BrowserJs.stepZoom(data.from, data.direction), data.to);
    }

    function test_nearestZoom() {
        compare(BrowserJs.nearestZoom(1.37), 1.25);
        compare(BrowserJs.zoomLabel(1.1), "110%");
    }

    function test_errors_data() {
        return [
            { tag: "dns", code: -105, explanation: "DNS address could not be found" },
            { tag: "refused", code: -102, explanation: "Connection refused" },
            { tag: "timed out", code: -118, explanation: "Connection timed out" },
            { tag: "offline", code: -106, explanation: "No internet connection" },
            { tag: "certificate", code: -202, explanation: "Certificate authority is not trusted" },
            { tag: "redirects", code: -310, explanation: "Too many redirects" }
        ];
    }

    function test_errors(data) {
        compare(BrowserJs.describeError(data.code, "").message, data.explanation);
    }

    function test_unknownError() {
        const named = BrowserJs.describeError(-999, "ERR_BLOCKED_BY_CLIENT");
        compare(named.name, "ERR_BLOCKED_BY_CLIENT");
        compare(named.message, "ERR_BLOCKED_BY_CLIENT");
        compare(BrowserJs.describeError(-999, "").message, "Network error");
    }

    function test_fitScalesDownAndCentres() {
        const shown = BrowserJs.fit(412, 915, 500, 500, 10);
        compare(shown.scale, 480 / 915);
        compare(shown.x, (500 - shown.width) / 2);
        compare(shown.y, 10);
    }

    function test_fitNeverScalesUp() {
        const shown = BrowserJs.fit(375, 667, 2000, 2000, 0);
        compare(shown.scale, 1);
        compare(shown.width, 375);
    }

    function test_viewports() {
        compare(BrowserJs.viewportOf("fill")._tag, "fill");
        const pixel = BrowserJs.viewportOf("pixel-7");
        compare(pixel._tag, "preset");
        compare(pixel.presetId, "pixel-7");
        compare(pixel.width, 412);
        compare(pixel.height, 915);
        const desktop = BrowserJs.viewportOf("desktop");
        compare(desktop._tag, "freeform");
        compare(desktop.width, 1440);
        const clamped = BrowserJs.viewportOf("custom", 100, 5000);
        compare(clamped.width, 240);
        compare(clamped.height, 3840);
    }

    function test_layoutDevicesEmpty() {
        compare(BrowserJs.layoutDevices([], 1000, 1000, 10, 10, 20).length, 0);
    }

    function test_layoutDevicesShareOneScaleInARow() {
        const frames = BrowserJs.layoutDevices(["iphone-12-pro", "ipad-air", "desktop"], 930, 1000, 15, 10, 20);
        compare(frames.length, 3);
        // Left to right, apart, at one scale and on one top line.
        compare(frames[1].x - (frames[0].x + frames[0].frameWidth), 15);
        compare(frames[2].x - (frames[1].x + frames[1].frameWidth), 15);
        compare(frames[0].scale, frames[2].scale);
        compare(frames[0].y, frames[2].y);
        // The row's middle is the area's, below the labels.
        compare(frames[1].y + frames[1].frameHeight / 2, (1000 + 20) / 2);
        // Centred: the row fills the width less its margins.
        compare(Math.round(frames[0].x), 10);
        compare(Math.round(frames[2].x + frames[2].frameWidth), 920);
    }

    function test_layoutDevicesNeverScalesUp() {
        const frames = BrowserJs.layoutDevices(["iphone-12-pro"], 4000, 4000, 0, 10, 20);
        compare(frames[0].scale, 1);
        compare(frames[0].frameWidth, 390);
        compare(frames[0].label, "iPhone 12 Pro");
        compare(frames[0].kind, "phone");
    }

    function test_layoutDevicesScalesDownToFit() {
        const frames = BrowserJs.layoutDevices(["desktop"], 400, 400, 0, 0, 0);
        compare(frames[0].scale, 400 / 1440);
        compare(frames[0].frameHeight, 900 * (400 / 1440));
    }
}
