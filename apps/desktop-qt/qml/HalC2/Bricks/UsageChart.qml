import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Shapes
import HalC2.Shell
import "js/usageChart.js" as UsageChartMath

// The usage page's chart, as the web's UsageProviderChart draws it: one smooth
// line per provider over the window's periods, each measured from zero with a
// faint fill beneath it, and the period under the pointer read out.
Item {
    id: chart

    // One line each: [{label, color, driverKind}].
    property var series: []
    // Oldest first: [{label, heading, values [one per series]}].
    property var columns: []
    // How a value is written on the axis and in the readout.
    property var format: value => String(value)
    // What the chart shows, for a screen reader.
    property string description

    // The column under the pointer, or -1.
    readonly property int hoveredIndex: !hover.hovered || columns.length === 0 || plot.width <= 0 ? -1 : Math.min(columns.length - 1, Math.max(0, Math.round(hover.point.position.x / plot.width * (columns.length - 1))))
    readonly property real stepX: columns.length > 1 ? plot.width / (columns.length - 1) : 0
    // The axis tops out at the largest single provider-period, not the sum:
    // layered lines each measure from zero.
    readonly property var axis: {
        let peak = 0;
        for (const column of columns) {
            for (const value of column.values)
                peak = Math.max(peak, value);
        }
        return UsageChartMath.niceScale(peak, 4);
    }
    // Each series' paths, the heaviest first so a lighter one is not buried.
    readonly property var lines: {
        const built = series.map((entry, index) => {
            const line = UsageChartMath.smoothPath(columns.map((column, at) => ({
                x: at * stepX,
                y: toY(column.values[index] ?? 0)
            })));
            return {
                color: entry.color,
                total: columns.reduce((sum, column) => sum + (column.values[index] ?? 0), 0),
                line: line,
                area: line === "" ? "" : line + " L" + plot.width.toFixed(2) + "," + plot.height + " L0," + plot.height + " Z"
            };
        });
        return built.sort((a, b) => b.total - a.total);
    }
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")

    // Room is left above the top gridline so a line at the peak is not cut.
    function toY(value) {
        return axis.max === 0 ? plot.height : plot.height - value / axis.max * (plot.height - 8);
    }

    implicitWidth: 320
    implicitHeight: plot.height + 4 + periodLabels.height
    Accessible.role: Accessible.Graphic
    Accessible.name: description

    component ChartLabel: Label {
        color: chart.muted
        font.pixelSize: 10
        font.features: {
            "tnum": 1
        }
    }

    Repeater {
        model: chart.axis.ticks

        delegate: ChartLabel {
            id: tick

            required property real modelData

            x: 56 - width
            y: chart.toY(tick.modelData) - height / 2
            text: tick.modelData === 0 ? "0" : chart.format(tick.modelData)
        }
    }

    Item {
        id: plot

        x: 64
        width: chart.width - x
        height: 224

        Repeater {
            model: chart.axis.ticks

            delegate: Rectangle {
                id: gridline

                required property real modelData

                y: Math.min(plot.height - 1, Math.round(chart.toY(gridline.modelData)))
                width: plot.width
                height: 1
                color: Theme.palette.color("border", "#27272a")
            }
        }

        // Every fill, then every line, so no series covers another's line.
        Repeater {
            model: chart.series.length

            delegate: Shape {
                id: fill

                required property int index
                readonly property var entry: chart.lines[index] ?? null

                preferredRendererType: Shape.CurveRenderer

                ShapePath {
                    strokeColor: "transparent"
                    fillColor: fill.entry ? Qt.alpha(fill.entry.color, 0.12) : "transparent"

                    PathSvg {
                        path: fill.entry ? fill.entry.area : ""
                    }
                }
            }
        }

        Repeater {
            model: chart.series.length

            delegate: Shape {
                id: stroke

                required property int index
                readonly property var entry: chart.lines[index] ?? null

                preferredRendererType: Shape.CurveRenderer

                ShapePath {
                    strokeColor: stroke.entry ? stroke.entry.color : "transparent"
                    strokeWidth: 2
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    joinStyle: ShapePath.RoundJoin

                    PathSvg {
                        path: stroke.entry ? stroke.entry.line : ""
                    }
                }
            }
        }

        Rectangle {
            visible: chart.hoveredIndex >= 0
            x: Math.min(plot.width - 1, Math.round(chart.hoveredIndex * chart.stepX))
            y: 8
            width: 1
            height: plot.height - y
            color: chart.muted
        }

        HoverHandler {
            id: hover
        }

        // The hovered period: each provider's part and their total, beside the
        // pointer and kept inside the plot.
        Rectangle {
            id: readout

            readonly property var column: chart.hoveredIndex < 0 ? null : chart.columns[chart.hoveredIndex]

            function beside(pointer, size, room) {
                const preferred = pointer + 12 + size <= room ? pointer + 12 : pointer - 12 - size;
                return Math.min(Math.max(0, preferred), Math.max(0, room - size));
            }

            objectName: "usageChartReadout"
            visible: column !== null
            x: beside(hover.point.position.x, width, plot.width)
            y: beside(hover.point.position.y, height, plot.height)
            width: Math.min(plot.width, Math.max(144, readoutRows.implicitWidth + 20))
            height: readoutRows.implicitHeight + 16
            radius: Math.min(Theme.radius, 12)
            color: Theme.palette.color("surfaceOverlay", "#18181b")
            border.color: Theme.palette.color("border", "#27272a")
            border.width: 1

            ColumnLayout {
                id: readoutRows

                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                anchors.topMargin: 8
                anchors.bottomMargin: 8
                spacing: 2

                Label {
                    objectName: "usageChartHeading"
                    Layout.bottomMargin: 2
                    text: readout.column ? readout.column.heading : ""
                    color: chart.muted
                    font.pixelSize: 12
                }

                Repeater {
                    model: chart.series

                    delegate: RowLayout {
                        id: part

                        required property var modelData
                        required property int index

                        Layout.fillWidth: true
                        spacing: 6

                        ProviderIcon {
                            driverKind: part.modelData.driverKind
                            size: 12
                        }

                        Label {
                            Layout.fillWidth: true
                            Layout.rightMargin: 6
                            text: part.modelData.label
                            color: chart.muted
                            font.pixelSize: 12
                        }

                        ChartLabel {
                            objectName: "usageChartValue_" + part.index
                            text: readout.column ? chart.format(readout.column.values[part.index] ?? 0) : ""
                            color: chart.foreground
                            font.pixelSize: 12
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: 2
                    implicitHeight: 1
                    color: Theme.palette.color("border", "#27272a")
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    Label {
                        Layout.fillWidth: true
                        Layout.rightMargin: 6
                        text: qsTr("Total")
                        color: chart.muted
                        font.pixelSize: 12
                    }

                    ChartLabel {
                        objectName: "usageChartTotal"
                        text: readout.column ? chart.format(readout.column.values.reduce((sum, value) => sum + value, 0)) : ""
                        color: chart.foreground
                        font.pixelSize: 12
                    }
                }
            }
        }
    }

    // The first, middle and last period, under the plot.
    Item {
        id: periodLabels

        function label(index) {
            const column = chart.columns[index];
            return column ? column.label : "";
        }

        x: plot.x
        y: plot.height + 4
        width: plot.width
        height: firstLabel.implicitHeight

        ChartLabel {
            id: firstLabel

            text: periodLabels.label(0)
            font.capitalization: Font.AllUppercase
        }

        ChartLabel {
            anchors.horizontalCenter: parent.horizontalCenter
            text: periodLabels.label(Math.floor(chart.columns.length / 2))
            font.capitalization: Font.AllUppercase
        }

        ChartLabel {
            anchors.right: parent.right
            text: periodLabels.label(chart.columns.length - 1)
            font.capitalization: Font.AllUppercase
        }
    }
}
