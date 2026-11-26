import QtQuick
import QtTest
import HalC2.Shell
import "../../../packages/qml/HalC2/Bricks"

// A badge's text and fill are one of the theme's readable pairs, never its
// tone drawn on a wash of itself.
TestCase {
    id: testCase
    name: "ShellBadgeTests"

    Component {
        id: badgeComponent
        ShellBadge {
            text: "Running"
        }
    }

    function init() {
        Theme.colors = {
            secondary: "#101010",
            secondaryForeground: "#fafafa",
            errorSurface: "#300000",
            errorForeground: "#ff8080",
            warningSurface: "#302000",
            warningForeground: "#ffd060",
            accentSurface: "#000000",
            accentSurfaceForeground: "#e0e0ff",
            success: "#00ff00"
        };
    }

    function cleanup() {
        Theme.colors = {};
    }

    function textOf(badge) {
        for (let i = 0; i < badge.children.length; ++i)
            if (badge.children[i].text === badge.text)
                return badge.children[i];
        return null;
    }

    function test_eachToneDrawsItsPair_data() {
        return [
            { tag: "error", tone: "error", fill: "#300000", ink: "#ff8080" },
            { tag: "warning", tone: "warning", fill: "#302000", ink: "#ffd060" },
            { tag: "info", tone: "info", fill: "#000000", ink: "#e0e0ff" },
            { tag: "neutral", tone: "neutral", fill: "#101010", ink: "#fafafa" },
            { tag: "success", tone: "success", fill: "#101010", ink: "#fafafa" }
        ];
    }

    function test_eachToneDrawsItsPair(data) {
        const badge = createTemporaryObject(badgeComponent, testCase, { tone: data.tone });
        verify(Qt.colorEqual(badge.color, data.fill), `${data.tone} fill ${badge.color}`);
        verify(Qt.colorEqual(textOf(badge).color, data.ink), `${data.tone} ink ${textOf(badge).color}`);
    }

    function test_successIsMarkedByItsBorder() {
        const badge = createTemporaryObject(badgeComponent, testCase, { tone: "success" });
        compare(badge.border.color.g, 1);
        compare(badge.border.color.r, 0);
    }

    function test_aPageSetsItsOwnSizeAndPadding() {
        const badge = createTemporaryObject(badgeComponent, testCase, {
            "font.pixelSize": 20,
            horizontalPadding: 6,
            verticalPadding: 2
        });
        const text = textOf(badge);
        compare(text.font.pixelSize, 20);
        compare(badge.implicitWidth, text.implicitWidth + 12);
        compare(badge.implicitHeight, text.implicitHeight + 4);
    }

    function test_emphasisStrengthensTheBorder() {
        const badge = createTemporaryObject(badgeComponent, testCase, { tone: "warning" });
        const plain = badge.border.color.a;
        badge.emphasised = true;
        verify(badge.border.color.a > plain, `${badge.border.color.a} over ${plain}`);
    }
}
