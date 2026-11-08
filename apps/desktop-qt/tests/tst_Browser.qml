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
            { tag: "spaces", input: "not an address" },
            { tag: "mailto", input: "mailto:alice@example.com" },
            { tag: "javascript without slashes", input: "javascript:alert(1)" },
            { tag: "no host", input: "http://" }
        ];
    }

    function test_refusedAddresses(data) {
        const result = BrowserJs.normalizeAddress(data.input);
        verify(result.url === undefined);
        verify(result.error.length > 0);
    }

    // Upstream #23577: a refusal says what to type instead.
    function test_refusalsSayWhatToType_data() {
        return [
            { tag: "file", input: "file:///etc/passwd", error: "Only http and https pages open here. Enter an http or https URL, such as https://example.com." },
            { tag: "ftp", input: "ftp://example.com", error: "Only http and https pages open here. Enter an http or https URL, such as https://example.com." },
            { tag: "mailto", input: "mailto:alice@example.com", error: "mailto: addresses do not open here. Enter an http or https URL, such as https://example.com." },
            { tag: "no host", input: "http://", error: "\"http://\" is not a web address. Enter an http or https URL, such as https://example.com." }
        ];
    }

    function test_refusalsSayWhatToType(data) {
        compare(BrowserJs.normalizeAddress(data.input).error, data.error);
    }

    function test_aPortIsNotAScheme() {
        compare(BrowserJs.normalizeAddress("example.com:8443/a").url, "https://example.com:8443/a");
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

    function test_sizesThePreviewRenders_data() {
        return [
            { tag: "smallest", width: 240, height: 800, allowed: true },
            { tag: "too narrow", width: 239, height: 800, allowed: false },
            { tag: "too short", width: 800, height: 239, allowed: false },
            { tag: "too wide", width: 3841, height: 800, allowed: false },
            { tag: "largest", width: 3840, height: 2160, allowed: true },
            { tag: "too large", width: 3840, height: 2161, allowed: false },
            { tag: "fractional", width: 500.5, height: 800, allowed: false },
            { tag: "not a number", width: Number("abc"), height: 800, allowed: false }
        ];
    }

    function test_sizesThePreviewRenders(data) {
        compare(BrowserJs.sizeAllowed(data.width, data.height), data.allowed);
    }

    function test_sizeAtRatioFollowsTheLeadingSide() {
        compare(BrowserJs.sizeAtRatio(2560, 16 / 9, "width"), { width: 2560, height: 1440 });
        compare(BrowserJs.sizeAtRatio(600, 0.5, "height"), { width: 300, height: 600 });
    }

    function test_sizeAtRatioKeepsBothSidesInBounds() {
        // 120 wide at 1:2 would be too narrow: the smallest that can is 240 by 480.
        compare(BrowserJs.sizeAtRatio(120, 0.5, "width"), { width: 240, height: 480 });
        const widest = BrowserJs.sizeAtRatio(5000, 16 / 9, "width");
        verify(BrowserJs.sizeAllowed(widest.width, widest.height));
        compare(widest.width, 3840);
    }

    function test_resizedFreely() {
        compare(BrowserJs.resized({ width: 400, height: 800 }, -100, 0, 0), { width: 300, height: 800 });
        compare(BrowserJs.resized({ width: 400, height: 800 }, -300, 0, 0), { width: 240, height: 800 });
        // Wider than the largest area: the side that moved gives way.
        compare(BrowserJs.resized({ width: 2000, height: 3840 }, 2000, 0, 0), { width: 2160, height: 3840 });
    }

    function test_resizedAtALockedRatio() {
        compare(BrowserJs.resized({ width: 400, height: 800 }, -100, 0, 0.5), { width: 300, height: 600 });
        compare(BrowserJs.resized({ width: 400, height: 800 }, 0, 200, 0.5), { width: 500, height: 1000 });
    }

    function test_draggedEdgeFollowsThePointerOnACentredPage() {
        // The page is centred, so its edge moving 50 pixels makes it 100 wider.
        compare(BrowserJs.dragged({ width: 400, height: 800 }, 50, 0, { width: 900, height: 1000 }, 1, 0), { width: 500, height: 800 });
        // Shown at half size, the edge moving 25 pixels makes it 100 wider.
        compare(BrowserJs.dragged({ width: 400, height: 800 }, 25, 0, { width: 900, height: 1000 }, 0.5, 0), { width: 500, height: 800 });
        compare(BrowserJs.dragged({ width: 400, height: 800 }, 0, -50, { width: 900, height: 1000 }, 1, 0), { width: 400, height: 700 });
    }

    function test_aSizePickedKeepsItsRatioOnlyIfTaken() {
        const phone = { _tag: "preset", width: 375, height: 667, presetId: "iphone-se" };
        const turned = { _tag: "freeform", width: 800, height: 500 };
        // Rotated with the ratio locked, then refused: the size and its ratio go back.
        compare(BrowserJs.ratioAnswered({ viewport: turned, ratio: 1.6, before: 0.625 }, { _tag: "freeform", width: 500, height: 800 }), 0.625);
        compare(BrowserJs.ratioAnswered({ viewport: turned, ratio: 1.6, before: 0.625 }, turned), 1.6);
        // A preset picked with the ratio locked, refused while the tab fills.
        compare(BrowserJs.ratioAnswered({ viewport: phone, ratio: 375 / 667, before: 0.5 }, { _tag: "fill" }), 0.5);
        compare(BrowserJs.ratioAnswered({ viewport: phone, ratio: 375 / 667, before: 0.5 }, phone), 375 / 667);
        // Another preset of the same size is another pick.
        compare(BrowserJs.ratioAnswered({ viewport: phone, ratio: 1, before: 0 }, Object.assign({}, phone, { presetId: "other" })), 0);
    }
}
