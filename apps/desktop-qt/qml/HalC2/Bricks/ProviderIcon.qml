import QtQuick
import QtQuick.Shapes
import HalC2.Shell
import "js/providerIcons.js" as ProviderIcons

// A provider instance's mark: the
// driver's glyph (or the ACP registry icon), initials when there is neither,
// and optionally the initials badge that tells two instances of one driver
// apart, filled with the instance's accent colour.
Item {
    id: icon

    property string driverKind: ""
    property string initials: ""
    property var accentColor: null
    property var iconUrl: null
    property bool showBadge: false
    property real size: 16
    // The surface under the badge, so its ring cuts it out of the glyph.
    property color indicatorBackground: Theme.palette.color("surfaceOverlay", "#18181b")

    readonly property var glyph: ProviderIcons.glyph(driverKind)
    readonly property string bitmap: iconUrl ? iconUrl : ProviderIcons.bitmap(driverKind)
    readonly property bool dark: Theme.palette.color("text", "#e4e4e7").hslLightness > 0.5
    readonly property var viewBox: glyph ? glyph.viewBox : [0, 0, 1, 1]
    readonly property real glyphScale: size / Math.max(viewBox[2], viewBox[3])

    implicitWidth: size
    implicitHeight: size
    Accessible.ignored: true

    Image {
        anchors.fill: parent
        visible: icon.bitmap.length > 0
        source: icon.bitmap.length > 0 ? (icon.iconUrl ? icon.bitmap : Qt.resolvedUrl(icon.bitmap)) : ""
        sourceSize: Qt.size(icon.size * 2, icon.size * 2)
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
    }

    Shape {
        visible: icon.bitmap.length === 0 && icon.glyph !== null
        width: icon.viewBox[0] + icon.viewBox[2]
        height: icon.viewBox[1] + icon.viewBox[3]
        preferredRendererType: Shape.CurveRenderer
        transform: [
            Translate {
                x: -icon.viewBox[0]
                y: -icon.viewBox[1]
            },
            Scale {
                xScale: icon.glyphScale
                yScale: icon.glyphScale
            },
            Translate {
                x: (icon.size - icon.viewBox[2] * icon.glyphScale) / 2
                y: (icon.size - icon.viewBox[3] * icon.glyphScale) / 2
            }
        ]

        ShapePath {
            id: firstPath

            readonly property var part: icon.glyph ? icon.glyph.paths[0] : null

            strokeColor: "transparent"
            fillColor: part ? (icon.dark ? part.dark : part.light) : "transparent"
            fillRule: part && part.evenOdd ? ShapePath.OddEvenFill : ShapePath.WindingFill

            PathSvg {
                path: firstPath.part ? firstPath.part.d : ""
            }
        }

        ShapePath {
            id: secondPath

            readonly property var part: icon.glyph && icon.glyph.paths.length > 1 ? icon.glyph.paths[1] : null

            strokeColor: "transparent"
            fillColor: part ? (icon.dark ? part.dark : part.light) : "transparent"
            fillRule: part && part.evenOdd ? ShapePath.OddEvenFill : ShapePath.WindingFill

            PathSvg {
                path: secondPath.part ? secondPath.part.d : ""
            }
        }
    }

    Text {
        anchors.centerIn: parent
        visible: icon.bitmap.length === 0 && icon.glyph === null
        text: icon.initials
        color: Theme.palette.color("text", "#e4e4e7")
        font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
        font.pixelSize: Math.max(8, Math.round(icon.size * 0.5))
        font.weight: Font.DemiBold
    }

    Rectangle {
        visible: icon.showBadge
        x: icon.size - width + 2
        y: icon.size - height + 2
        height: Math.max(10, Math.round(icon.size * 0.6))
        width: Math.max(height, badgeText.implicitWidth + 4)
        radius: height / 2
        color: icon.accentColor ? icon.accentColor : Theme.palette.color("card", "#18181b")
        border.color: icon.indicatorBackground
        border.width: 1

        Text {
            id: badgeText

            anchors.centerIn: parent
            text: icon.initials
            color: icon.accentColor ? "#ffffff" : Theme.palette.color("textMuted", "#8b8b93")
            font.family: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family
            font.pixelSize: Math.max(6, Math.round(parent.height * 0.6))
            font.weight: Font.DemiBold
        }
    }
}
