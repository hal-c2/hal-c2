import QtQuick
import HalC2.Shell

// A small pill of text, such as a plugin's mark beside a thread's row. Its
// `tone` picks a theme pair whose text reads on its fill: "error" and
// "warning" their surfaces, "info" the accent surface, and "neutral" and
// "success" the secondary fill, success marked by its border, since no theme
// has a success surface. `emphasised` strengthens the border, for a badge
// that wants the user.
Rectangle {
    id: badge

    property string text
    property string tone: "neutral"
    property bool emphasised: false
    property int horizontalPadding: 5
    property int verticalPadding: 1
    property alias font: label.font
    readonly property color ink: {
        switch (tone) {
        case "error":
            return Theme.palette.color("errorForeground", "#f87171");
        case "warning":
            return Theme.palette.color("warningForeground", "#fbbf24");
        case "info":
            return Theme.palette.color("accentSurfaceForeground", "#f2f3f5");
        default:
            return Theme.palette.color("secondaryForeground", "#f2f3f5");
        }
    }
    readonly property color edge: {
        switch (tone) {
        case "success":
            return Theme.palette.color("success", "#4ade80");
        case "neutral":
            return Theme.palette.color("secondaryForeground", "#f2f3f5");
        default:
            return badge.ink;
        }
    }
    readonly property color secondary: Theme.palette.color("secondary", "#1c1f24")

    implicitWidth: label.implicitWidth + 2 * horizontalPadding
    implicitHeight: label.implicitHeight + 2 * verticalPadding
    radius: height / 2
    color: {
        switch (tone) {
        case "error":
            return Theme.palette.color("errorSurface", "#2a1618");
        case "warning":
            return Theme.palette.color("warningSurface", "#2a2210");
        case "info":
            // The accent surface is a wash, so it lies on the secondary fill.
            return Qt.tint(badge.secondary, Theme.palette.color("accentSurface", "#27272a"));
        default:
            return badge.secondary;
        }
    }
    border.color: Qt.alpha(edge, emphasised ? 0.7 : 0.35)

    Text {
        id: label

        anchors.centerIn: parent
        text: badge.text
        color: badge.ink
        font.pixelSize: Math.round(10 * Theme.fontScale)
        font.weight: Font.Medium
    }
}
