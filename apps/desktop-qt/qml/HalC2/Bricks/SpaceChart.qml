pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import HalC2.Shell
import "js/spaceChart.js" as SpaceChartMath
import "js/usageChart.js" as UsageChartMath

// A chart block drawn from its description (SpaceChart in packages/contracts):
// bars or a line, where its numbers came from, and the numbers themselves on
// request. The description is untrusted data: every string in it is shown as
// plain text. It draws once and again only when the data or its size changes.
ColumnLayout {
    id: view

    objectName: "spaceChart"

    property var chart: ({})
    property bool numbersShown: false

    readonly property var seriesList: chart.series ?? []
    readonly property var scale: UsageChartMath.niceScale(SpaceChartMath.peak(chart), 4)
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property real fontSize: Math.round(12 * Theme.fontScale)
    // The first four categorical hues in order, one step for each appearance,
    // checked against both surfaces; a chart holds at most four series.
    readonly property var hues: Theme.appearance === "dark" ? ["#3987e5", "#d95926", "#199e70", "#c98500"] : ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]

    spacing: 6
    Accessible.role: Accessible.Graphic
    Accessible.name: qsTr("%1 chart: %2. %3").arg(chart.type ?? "").arg(chart.title ?? "").arg(chart.source ?? "")

    Text {
        objectName: "spaceChartTitle"
        Layout.fillWidth: true
        text: view.chart.title ?? ""
        textFormat: Text.PlainText
        color: view.foreground
        font.pixelSize: Math.round(15 * Theme.fontScale)
        font.weight: Font.DemiBold
        wrapMode: Text.Wrap
    }

    Item {
        id: plot

        readonly property real axis: Math.round(36 * Theme.fontScale)
        readonly property real under: Math.round(20 * Theme.fontScale)
        readonly property real marksWidth: Math.max(0, width - axis)
        readonly property real marksHeight: Math.max(0, height - under - 6)

        Layout.fillWidth: true
        Layout.preferredHeight: Math.round(170 * Theme.fontScale)

        Repeater {
            model: view.scale.ticks

            delegate: Item {
                id: tick

                required property var modelData

                readonly property real rowY: 6 + plot.marksHeight - (view.scale.max > 0 ? tick.modelData / view.scale.max : 0) * plot.marksHeight

                Rectangle {
                    x: plot.axis
                    y: tick.rowY
                    width: plot.marksWidth
                    height: 1
                    color: Theme.palette.color("border", "#27272a")
                }

                Text {
                    x: 0
                    y: tick.rowY - height / 2
                    width: plot.axis - 6
                    horizontalAlignment: Text.AlignRight
                    text: SpaceChartMath.compact(tick.modelData)
                    textFormat: Text.PlainText
                    color: view.muted
                    font.pixelSize: view.fontSize
                    font.features: ({
                        "tnum": 1
                    })
                }
            }
        }

        Item {
            x: plot.axis
            y: 6
            width: plot.marksWidth
            height: plot.marksHeight

            Repeater {
                model: view.chart.type === "bar" ? SpaceChartMath.bars(view.chart, view.scale.max, plot.marksWidth, plot.marksHeight) : []

                delegate: Rectangle {
                    required property var modelData

                    objectName: "spaceChartBar"
                    x: modelData.x
                    y: modelData.y
                    width: modelData.width
                    height: modelData.height
                    topLeftRadius: Math.min(4, width / 2)
                    topRightRadius: Math.min(4, width / 2)
                    color: view.hues[modelData.series]
                }
            }

            Repeater {
                model: view.chart.type === "line" ? SpaceChartMath.lines(view.chart, view.scale.max, plot.marksWidth, plot.marksHeight) : []

                delegate: Item {
                    id: line

                    required property var modelData

                    anchors.fill: parent

                    Shape {
                        objectName: "spaceChartLine"
                        anchors.fill: parent
                        preferredRendererType: Shape.CurveRenderer

                        ShapePath {
                            fillColor: "transparent"
                            strokeColor: view.hues[line.modelData.series]
                            strokeWidth: 2
                            joinStyle: ShapePath.RoundJoin
                            capStyle: ShapePath.RoundCap

                            PathSvg {
                                path: line.modelData.path
                            }
                        }
                    }

                    Repeater {
                        model: line.modelData.points

                        delegate: Rectangle {
                            required property var modelData

                            x: modelData.x - 4
                            y: modelData.y - 4
                            width: 8
                            height: 8
                            radius: 4
                            color: view.hues[modelData.series]
                        }
                    }
                }
            }
        }

        Repeater {
            model: SpaceChartMath.ticks(view.chart, plot.marksWidth, Math.round(64 * Theme.fontScale))

            delegate: Text {
                required property var modelData

                objectName: "spaceChartLabel:" + modelData.text
                x: plot.axis + modelData.x
                y: plot.height - plot.under + 4
                width: modelData.width
                horizontalAlignment: modelData.align === "left" ? Text.AlignLeft : modelData.align === "right" ? Text.AlignRight : Text.AlignHCenter
                elide: Text.ElideRight
                text: modelData.text
                textFormat: Text.PlainText
                color: view.muted
                font.pixelSize: view.fontSize
            }
        }
    }

    Flow {
        objectName: "spaceChartLegend"
        Layout.fillWidth: true
        visible: view.seriesList.length > 1
        spacing: 12

        Repeater {
            model: view.seriesList.length > 1 ? view.seriesList : []

            delegate: Row {
                id: entry

                required property var modelData
                required property int index

                spacing: 6

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 10
                    height: 10
                    radius: 2
                    color: view.hues[entry.index]
                }

                Text {
                    text: entry.modelData.name
                    textFormat: Text.PlainText
                    color: view.foreground
                    font.pixelSize: view.fontSize
                }
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 8

        Text {
            objectName: "spaceChartSource"
            Layout.fillWidth: true
            text: view.chart.source ?? ""
            textFormat: Text.PlainText
            color: view.muted
            font.pixelSize: view.fontSize
            wrapMode: Text.Wrap
        }

        ShellButton {
            objectName: "spaceChartNumbers"
            subtle: true
            implicitHeight: 26
            text: view.numbersShown ? qsTr("Hide numbers") : qsTr("Numbers")
            onClicked: view.numbersShown = !view.numbersShown
        }
    }

    // Built only while it is shown.
    Grid {
        objectName: "spaceChartTable"
        Layout.fillWidth: true
        visible: view.numbersShown
        columns: view.seriesList.length + 1
        columnSpacing: 16
        rowSpacing: 2

        Repeater {
            model: view.numbersShown ? SpaceChartMath.cells(view.chart) : []

            delegate: Text {
                required property var modelData

                objectName: "spaceChartCell:" + modelData
                // A Grid skips an item with no width, which the empty corner would be.
                width: Math.max(1, implicitWidth)
                text: modelData
                textFormat: Text.PlainText
                color: view.foreground
                font.pixelSize: view.fontSize
                font.features: ({
                    "tnum": 1
                })
            }
        }
    }
}
