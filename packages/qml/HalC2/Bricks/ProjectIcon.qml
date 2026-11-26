import QtQuick
import HalC2.Shell

// A project's icon as `projectIcons` describes it (IdentityController): a
// monogram tile, an emoji, a symbol in its colour, or an image the MC serves.
// A project with no icon yet draws its name's first letter in a neutral tile
// when given `name`, and nothing without it. An image that has not loaded
// (yet, or at all) shows the project's monogram in its colour until it does.
//
//   ProjectIcon { icon: Shell.state.projectIcons?.[projectKey] ?? null; name: projectName }
Item {
    id: root

    property var icon: null
    property string name: ""
    property real size: 16
    readonly property string fallbackText: name.trim().charAt(0).toUpperCase()
    readonly property string kind: icon?.kind ?? (fallbackText.length > 0 ? "monogram" : "")
    readonly property color tint: icon?.tint ?? Theme.palette.color("inkTertiary", "#8b919e")
    // The raised surface in the project's colour, so the colour carries
    // at the sidebar's 14px.
    readonly property color monogramBackground: Qt.tint(Theme.palette.color("surfaceRaised", "#1c1f26"), Qt.alpha(tint, 0.22))
    // The project's colour, deepened or lightened in its own hue until the
    // letters stand out from their tile at 4.5:1 (WCAG 2.2 1.4.3): a vivid
    // colour on its own tint is only about 2.5:1. A tile its hue cannot
    // clear (a mid grey) gets black or white, one of which always does.
    readonly property color monogramForeground: readableTint(tint, monogramBackground)

    function readableTint(foreground, background) {
        function luminance(c) {
            function channel(v) {
                return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
            }
            return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
        }
        function contrast(a, b) {
            const light = Math.max(luminance(a), luminance(b));
            const dark = Math.min(luminance(a), luminance(b));
            return (light + 0.05) / (dark + 0.05);
        }
        if (contrast(foreground, background) >= 4.6) {
            return foreground;
        }
        // Move toward whichever extreme, black or white, stands out more.
        const deepen = contrast(Qt.rgba(0, 0, 0, 1), background) > contrast(Qt.rgba(1, 1, 1, 1), background);
        const hue = foreground.hslHue < 0 ? 0 : foreground.hslHue;
        const saturation = foreground.hslSaturation < 0 ? 0 : foreground.hslSaturation;
        let lightness = foreground.hslLightness;
        let candidate = foreground;
        for (let step = 0; step < 24 && contrast(candidate, background) < 4.6; step++) {
            lightness = deepen ? Math.max(0.02, lightness - 0.04) : Math.min(0.98, lightness + 0.04);
            candidate = Qt.hsla(hue, saturation, lightness, 1);
        }
        if (contrast(candidate, background) >= 4.5)
            return candidate;
        return deepen ? Qt.rgba(0, 0, 0, 1) : Qt.rgba(1, 1, 1, 1);
    }

    implicitWidth: size
    implicitHeight: size
    visible: kind.length > 0
    Accessible.ignored: true

    Rectangle {
        objectName: "projectIconMonogram"
        anchors.fill: parent
        visible: root.kind === "monogram" || (root.kind === "image" && image.status !== Image.Ready && root.fallbackText.length > 0)
        radius: Theme.radiusXs
        color: root.monogramBackground

        Text {
            objectName: "projectIconMonogramText"
            anchors.centerIn: parent
            text: root.icon?.text ?? root.fallbackText
            color: root.monogramForeground
            font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
            // Large enough to read on the sidebar's 14px mark, and never
            // below the 10px smallest reading size; two letters still fit.
            font.pixelSize: Math.max(10, Math.round(root.size * 0.64))
            font.weight: Font.DemiBold
        }
    }
    Text {
        objectName: "projectIconEmoji"
        anchors.centerIn: parent
        visible: root.kind === "emoji"
        text: root.icon?.emoji ?? ""
        font.pixelSize: Math.round(root.size * 0.8)
    }
    ShellIcon {
        objectName: "projectIconSymbol"
        anchors.centerIn: parent
        visible: root.kind === "lucide"
        name: root.icon?.name ?? ""
        size: root.size * 0.875
        color: root.tint
    }
    Image {
        id: image
        objectName: "projectIconImage"
        anchors.fill: parent
        visible: root.kind === "image" && status === Image.Ready
        source: root.kind === "image" ? root.icon.url : ""
        sourceSize: Qt.size(root.size * 2, root.size * 2)
        fillMode: Image.PreserveAspectFit
        asynchronous: true
    }
}
