.pragma library

// What the in-app browser (BrowserPanel) decides without a page: the address
// a user typed, the zoom ladder, why a page failed and how a device size fits.
// Mirrors the web client's preview helpers (packages/shared/src/preview.ts,
// packages/contracts/src/preview.ts) so both read an address the same way.

// The contract's zoom ladder (PREVIEW_ZOOM_STEPS).
var zoomSteps = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0];

// The contract's device presets (PreviewViewportPresetId), in Chrome
// DevTools' order, with the device pixel ratio Chrome emulates them at.
var presets = [
    { id: "iphone-se", label: "iPhone SE", width: 375, height: 667, dpr: 2, kind: "phone" },
    { id: "iphone-xr", label: "iPhone XR", width: 414, height: 896, dpr: 2, kind: "phone" },
    { id: "iphone-12-pro", label: "iPhone 12 Pro", width: 390, height: 844, dpr: 3, kind: "phone" },
    { id: "iphone-14-pro-max", label: "iPhone 14 Pro Max", width: 430, height: 932, dpr: 3, kind: "phone" },
    { id: "pixel-7", label: "Pixel 7", width: 412, height: 915, dpr: 2.625, kind: "phone" },
    { id: "samsung-galaxy-s8-plus", label: "Samsung Galaxy S8+", width: 360, height: 740, dpr: 4, kind: "phone" },
    { id: "samsung-galaxy-s20-ultra", label: "Samsung Galaxy S20 Ultra", width: 412, height: 915, dpr: 3.5, kind: "phone" },
    { id: "ipad-mini", label: "iPad Mini", width: 768, height: 1024, dpr: 2, kind: "tablet" },
    { id: "ipad-air", label: "iPad Air", width: 820, height: 1180, dpr: 2, kind: "tablet" },
    { id: "ipad-pro", label: "iPad Pro", width: 1024, height: 1366, dpr: 2, kind: "tablet" },
    { id: "surface-pro-7", label: "Surface Pro 7", width: 912, height: 1368, dpr: 2, kind: "tablet" },
    { id: "surface-duo", label: "Surface Duo", width: 540, height: 720, dpr: 2.5, kind: "phone" },
    { id: "galaxy-z-fold-5", label: "Galaxy Z Fold 5", width: 344, height: 882, dpr: 2.625, kind: "phone" },
    { id: "asus-zenbook-fold", label: "Asus Zenbook Fold", width: 853, height: 1280, dpr: 1.5, kind: "tablet" },
    { id: "samsung-galaxy-a51-71", label: "Samsung Galaxy A51/71", width: 412, height: 914, dpr: 2.625, kind: "phone" },
    { id: "nest-hub", label: "Nest Hub", width: 1024, height: 600, dpr: 2, kind: "tablet" },
    { id: "nest-hub-max", label: "Nest Hub Max", width: 1280, height: 800, dpr: 2, kind: "tablet" }
];

// The desktop width the Devices view adds beside the presets; the contract
// has no desktop preset, so the MC hears it as a freeform size.
var desktop = { id: "desktop", label: "Desktop", width: 1440, height: 900, dpr: 1, kind: "desktop" };

// The Devices view's starting set: a phone, a tablet, and the desktop width.
var defaultDevicesPresetIds = ["iphone-12-pro", "ipad-air", "desktop"];

// The contract's viewport bounds (PREVIEW_VIEWPORT_*).
var minSide = 240;
var maxSide = 3840;
var maxArea = 3840 * 2160;

function preset(id) {
    if (id === desktop.id)
        return desktop;
    for (var i = 0; i < presets.length; ++i) {
        if (presets[i].id === id)
            return presets[i];
    }
    return null;
}

// The address a user typed, as a URL: {url} or {error}. A loopback host
// (localhost, 127.0.0.1, 0.0.0.0, [::1]) gets http, anything else https;
// only http and https pages open.
function normalizeAddress(input) {
    var trimmed = String(input === undefined || input === null ? "" : input).trim();
    if (trimmed.length === 0)
        return { error: "Enter a web address." };
    var withScheme = trimmed;
    if (trimmed.indexOf("://") < 0) {
        var loopback = /^(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\])(?::|\/|$)/i.test(trimmed);
        withScheme = (loopback ? "http://" : "https://") + trimmed;
    }
    var named = /^([a-z][a-z0-9+.-]*):\/\//i.exec(withScheme);
    var scheme = named ? named[1].toLowerCase() : "";
    if (named && scheme !== "http" && scheme !== "https")
        return { error: "Only http and https pages open here." };
    var match = /^([a-z][a-z0-9+.-]*):\/\/([^/?#\s]+)(.*)$/i.exec(withScheme);
    if (!match || /\s/.test(match[3]))
        return { error: "\"" + trimmed + "\" is not a web address." };
    var rest = match[3].length === 0 ? "/" : match[3];
    return { url: scheme + "://" + match[2] + rest };
}

// The ladder's step nearest `zoom`.
function nearestZoom(zoom) {
    var best = zoomSteps[0];
    for (var i = 1; i < zoomSteps.length; ++i) {
        if (Math.abs(zoomSteps[i] - zoom) < Math.abs(best - zoom))
            best = zoomSteps[i];
    }
    return best;
}

// One step in (direction 1) or out (-1) from `zoom`, staying at the ends.
function stepZoom(zoom, direction) {
    var at = zoomSteps.indexOf(nearestZoom(zoom));
    return zoomSteps[Math.max(0, Math.min(zoomSteps.length - 1, at + (direction > 0 ? 1 : -1)))];
}

function zoomLabel(zoom) {
    return Math.round(zoom * 100) + "%";
}

// Chromium's net error codes, by the name the web client keys its messages on.
var errorNames = {
    "-105": "ERR_NAME_NOT_RESOLVED",
    "-137": "ERR_NAME_RESOLUTION_FAILED",
    "-102": "ERR_CONNECTION_REFUSED",
    "-101": "ERR_CONNECTION_RESET",
    "-100": "ERR_CONNECTION_CLOSED",
    "-118": "ERR_CONNECTION_TIMED_OUT",
    "-106": "ERR_INTERNET_DISCONNECTED",
    "-7": "ERR_TIMED_OUT",
    "-202": "ERR_CERT_AUTHORITY_INVALID",
    "-200": "ERR_CERT_COMMON_NAME_INVALID",
    "-201": "ERR_CERT_DATE_INVALID",
    "-310": "ERR_TOO_MANY_REDIRECTS"
};

var errorMessages = {
    "ERR_NAME_NOT_RESOLVED": "DNS address could not be found",
    "ERR_NAME_RESOLUTION_FAILED": "DNS address could not be found",
    "ERR_CONNECTION_REFUSED": "Connection refused",
    "ERR_CONNECTION_RESET": "Connection was reset",
    "ERR_CONNECTION_CLOSED": "Connection was closed",
    "ERR_CONNECTION_TIMED_OUT": "Connection timed out",
    "ERR_INTERNET_DISCONNECTED": "No internet connection",
    "ERR_TIMED_OUT": "Connection timed out",
    "ERR_CERT_AUTHORITY_INVALID": "Certificate authority is not trusted",
    "ERR_CERT_COMMON_NAME_INVALID": "Certificate hostname mismatch",
    "ERR_CERT_DATE_INVALID": "Certificate is expired or not yet valid",
    "ERR_TOO_MANY_REDIRECTS": "Too many redirects"
};

// Why a page failed, in plain words: {name, message}. `code` is Chromium's
// (negative) net error, `description` what the engine said.
function describeError(code, description) {
    var name = errorNames[String(code)] || "";
    if (!name && /^ERR_[A-Z_]+$/.test(String(description || "")))
        name = String(description);
    var message = errorMessages[name] || "";
    if (!message)
        message = description ? String(description) : "Network error";
    return { name: name || (code ? "ERR_" + Math.abs(code) : "ERR_FAILED"), message: message };
}

function hostOf(url) {
    var match = /^[a-z][a-z0-9+.-]*:\/\/([^/?#]+)/i.exec(String(url || ""));
    return match ? match[1] : String(url || "");
}

// How a page `width` x `height` CSS pixels fits `areaWidth` x `areaHeight`
// with `margin` around it: {scale, width, height, x, y}, never scaled up.
function fit(width, height, areaWidth, areaHeight, margin) {
    var pad = margin === undefined ? 0 : margin;
    var roomWidth = Math.max(1, areaWidth - 2 * pad);
    var roomHeight = Math.max(1, areaHeight - 2 * pad);
    var scale = Math.min(1, roomWidth / width, roomHeight / height);
    var shownWidth = width * scale;
    var shownHeight = height * scale;
    return {
        scale: scale,
        width: shownWidth,
        height: shownHeight,
        x: (areaWidth - shownWidth) / 2,
        y: (areaHeight - shownHeight) / 2
    };
}

// The Devices view's frames: one row, `spacing` apart and `margin` in from
// the area's edges, every device at one shared scale (never up) so they keep
// their sizes relative to each other. Their tops line up, a `labelHeight`
// strip above them for labels, and the row is centred in the area.
// {id, label, kind, dpr, width, height (the device's CSS viewport), scale,
// frameWidth, frameHeight, x, y}.
function layoutDevices(ids, areaWidth, areaHeight, spacing, margin, labelHeight) {
    var gap = spacing === undefined ? 0 : spacing;
    var label = labelHeight === undefined ? 0 : labelHeight;
    var pad = margin === undefined ? 0 : margin;
    var devices = [];
    var total = 0;
    var tallest = 0;
    for (var i = 0; i < ids.length; ++i) {
        var device = preset(ids[i]) || desktop;
        devices.push(device);
        total += device.width;
        tallest = Math.max(tallest, device.height);
    }
    if (devices.length === 0)
        return [];
    var roomWidth = Math.max(1, areaWidth - 2 * pad - gap * (devices.length - 1));
    var roomHeight = Math.max(1, areaHeight - 2 * pad - label);
    var scale = Math.min(1, roomWidth / total, roomHeight / tallest);
    var x = (areaWidth - total * scale - gap * (devices.length - 1)) / 2;
    var frames = [];
    for (var j = 0; j < devices.length; ++j) {
        var shown = devices[j];
        frames.push({
            id: shown.id,
            label: shown.label,
            kind: shown.kind,
            dpr: shown.dpr,
            width: shown.width,
            height: shown.height,
            scale: scale,
            frameWidth: shown.width * scale,
            frameHeight: shown.height * scale,
            x: x,
            y: (areaHeight - label - tallest * scale) / 2 + label
        });
        x += shown.width * scale + gap;
    }
    return frames;
}

// The contract's viewport setting for a preset or freeform size, clamped to
// its bounds.
function viewportOf(id, width, height) {
    if (id === "fill")
        return { _tag: "fill" };
    var shown = preset(id);
    var w = Math.max(minSide, Math.min(maxSide, Math.round(shown ? shown.width : width)));
    var h = Math.max(minSide, Math.min(maxSide, Math.round(shown ? shown.height : height)));
    if (w * h > maxArea)
        h = Math.floor(maxArea / w);
    if (shown && shown.kind !== "desktop")
        return { _tag: "preset", width: w, height: h, presetId: shown.id };
    return { _tag: "freeform", width: w, height: h };
}

// A start page suggestion's label: the server's process, else the host.
function suggestionLabel(suggestion) {
    if (suggestion.label)
        return suggestion.label;
    return hostOf(suggestion.url);
}
