pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtQuick.Shapes
import HalC2.Shell

// How full the open thread's context window is, as the web's composer showed
// it: a ring in the composer's toolbar, red past nine tenths, whose details
// (a click) read the usage, what the thread has processed and what it cost.
// Behind the "Context window indicator" setting, and only once the provider
// has reported (Threads.timeline.contextWindow).
AbstractButton {
    id: meter

    // False where the composer is not a thread's (an images host).
    property bool available: true
    readonly property var usage: Threads.timeline ? Threads.timeline.contextWindow : ({})
    readonly property bool reported: usage.reading !== undefined
    readonly property bool enabledInSettings: {
        Settings.device;
        return Settings.setting("contextWindowMeterEnabled") === true;
    }
    readonly property real fraction: Math.max(0, Math.min(100, usage.percent ?? 0)) / 100
    readonly property color usedColor: usage.nearlyFull === true ? Theme.palette.color("error", "#ef4444") : Theme.palette.color("textMuted", "#8b8b93")

    objectName: "contextWindowMeter"
    visible: available && reported && enabledInSettings
    implicitWidth: 28
    implicitHeight: 28
    hoverEnabled: true
    Accessible.name: (usage.maxTokens ?? 0) > 0 ? qsTr("Context window %1 used").arg(usage.percentLabel) : qsTr("Context window %1 tokens used").arg(usage.reading ?? "")
    onClicked: details.opened ? details.close() : details.open()

    background: Rectangle {
        radius: Theme.radiusMd
        color: meter.hovered || details.opened ? Theme.palette.color("surfaceRaised", "#27272a") : "transparent"
    }

    contentItem: Item {
        Shape {
            anchors.centerIn: parent
            width: 20
            height: 20
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                fillColor: "transparent"
                strokeColor: Qt.alpha(Theme.palette.color("textMuted", "#8b8b93"), 0.24)
                strokeWidth: 2.5
                PathAngleArc {
                    centerX: 10
                    centerY: 10
                    radiusX: 8
                    radiusY: 8
                    startAngle: 0
                    sweepAngle: 360
                }
            }

            ShapePath {
                fillColor: "transparent"
                strokeColor: meter.usedColor
                strokeWidth: 2.5
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: 10
                    centerY: 10
                    radiusX: 8
                    radiusY: 8
                    startAngle: -90
                    sweepAngle: 360 * meter.fraction
                }
            }
        }
    }

    ShellPopover {
        id: details

        scale: Shell.state.layout?.zoom ?? 1
        transformOrigin: Item.BottomRight
        x: meter.width - width
        y: -height - Theme.space.xs
        width: 240
        padding: Theme.space.md

        ColumnLayout {
            objectName: "contextWindowDetails"
            width: details.availableWidth
            spacing: Theme.space.sm

            RowLayout {
                Layout.fillWidth: true
                Label {
                    Layout.fillWidth: true
                    text: qsTr("Context Window")
                    color: Theme.palette.color("textMuted", "#8b8b93")
                    font.pixelSize: Theme.type.caption.size
                    font.weight: Font.Medium
                }
                Label {
                    objectName: "contextWindowReading"
                    text: meter.usage.reading ?? ""
                    color: meter.usage.nearlyFull === true ? meter.usedColor : Theme.palette.color("text", "#e4e4e7")
                    font.pixelSize: Theme.type.caption.size
                    font.features: {
                        "tnum": 1
                    }
                }
            }

            // How full, as a bar, when the window's size is known.
            Rectangle {
                visible: (meter.usage.maxTokens ?? 0) > 0
                Layout.fillWidth: true
                implicitHeight: 6
                radius: 3
                color: Qt.alpha(Theme.palette.color("textMuted", "#8b8b93"), 0.2)
                Rectangle {
                    width: parent.width * meter.fraction
                    height: parent.height
                    radius: 3
                    color: meter.usedColor
                }
            }

            component Fact: RowLayout {
                id: fact
                property string label
                property string value
                visible: value.length > 0
                Layout.fillWidth: true
                Label {
                    Layout.fillWidth: true
                    text: fact.label
                    color: Theme.palette.color("textMuted", "#8b8b93")
                    font.pixelSize: Theme.type.caption.size
                }
                Label {
                    objectName: "contextWindowFact:" + fact.label
                    text: fact.value
                    color: Theme.palette.color("textMuted", "#8b8b93")
                    font.pixelSize: Theme.type.caption.size
                    font.weight: Font.Medium
                }
            }

            Fact {
                label: qsTr("Total processed")
                value: meter.usage.processed ?? ""
            }
            Fact {
                label: qsTr("Cost")
                value: meter.usage.cost ?? ""
            }
        }
    }
}
