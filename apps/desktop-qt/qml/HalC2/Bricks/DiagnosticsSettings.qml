pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → Diagnostics, natively (the web's DiagnosticsSettings): the
// processes this MC started, its resource history and recent trace
// failures, as DiagnosticsController publishes them
// (features/settings/diagnostics.feature).
SettingsPage {
    id: diagnostics

    readonly property var settings: Shell.state.diagnostics ?? null
    readonly property var processes: settings?.processes ?? ({})
    readonly property var history: settings?.history ?? ({})
    readonly property var traces: settings?.traces ?? ({})
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color danger: Theme.palette.color("error", "#ef4444")

    objectName: "diagnosticsSettings"
    title: qsTr("Diagnostics")

    component Heading: ColumnLayout {
        property alias text: label.text
        default property alias trailing: extra.data

        Layout.fillWidth: true
        Layout.topMargin: 12
        spacing: 6

        RowLayout {
            Layout.fillWidth: true

            Label {
                id: label
                Layout.fillWidth: true
                color: Theme.palette.color("text", "#e4e4e7")
                font.pixelSize: Math.round(14 * Theme.fontScale)
                font.weight: Font.DemiBold
            }

            RowLayout {
                id: extra
                spacing: 6
            }
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: Theme.palette.color("border", "#27272a")
        }
    }

    // A row of labelled figures.
    component Stats: RowLayout {
        id: stats

        property var figures: []

        Layout.fillWidth: true
        spacing: 24

        Repeater {
            model: stats.figures

            ColumnLayout {
                id: figure

                required property var modelData
                spacing: 2

                Label {
                    text: figure.modelData[0]
                    color: Theme.palette.color("textMuted", "#a1a1aa")
                    font.pixelSize: Math.round(11 * Theme.fontScale)
                }

                Label {
                    objectName: "stat:" + figure.modelData[0]
                    text: figure.modelData[1]
                    color: Theme.palette.color("text", "#e4e4e7")
                    font.pixelSize: Math.round(14 * Theme.fontScale)
                    font.weight: Font.Medium
                }
            }
        }
    }

    component Failure: Label {
        property string message: ""

        Layout.fillWidth: true
        visible: message.length > 0
        text: message
        color: Theme.palette.color("error", "#ef4444")
        font.pixelSize: Math.round(12 * Theme.fontScale)
        wrapMode: Text.Wrap
    }

    // Cells in fixed columns, the first one taking what is left.
    component Cells: RowLayout {
        id: row

        property var cells: []
        property bool header: false

        Layout.fillWidth: true
        spacing: 12

        Repeater {
            model: row.cells

            Label {
                required property var modelData
                required property int index

                Layout.fillWidth: index === 0
                Layout.preferredWidth: index === 0 ? -1 : 80
                text: modelData
                elide: Text.ElideRight
                color: row.header ? Theme.palette.color("textMuted", "#a1a1aa") : Theme.palette.color("text", "#e4e4e7")
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }
        }
    }

    ShellButton {
        objectName: "diagnosticsRefresh"
        Layout.alignment: Qt.AlignRight
        text: qsTr("Refresh")
        iconName: "refresh-cw"
        enabled: !(diagnostics.processes.loading || diagnostics.history.loading || diagnostics.traces.loading)
        onClicked: Shell.dispatch("diagnostics.refresh")
    }

    Heading {
        text: qsTr("Live Processes")
    }

    Stats {
        figures: [[qsTr("Child Processes"), diagnostics.processes.count ?? "..."], [qsTr("CPU"), diagnostics.processes.cpu ?? "..."],
                  [qsTr("Memory"), diagnostics.processes.memory ?? "..."], [qsTr("Server PID"), diagnostics.processes.serverPid ?? "..."]]
    }

    Failure {
        message: diagnostics.processes.error ?? ""
    }

    Cells {
        header: true
        cells: [qsTr("Name"), qsTr("CPU"), qsTr("Memory"), qsTr("PID"), qsTr("Type"), ""]
    }

    // The processes, grouped by what they are for; a group folds away.
    Repeater {
        model: diagnostics.processes.groups ?? [{ id: "", label: "", count: 0, collapsed: false, rows: diagnostics.processes.rows ?? [] }]

        ColumnLayout {
            id: group

            required property var modelData

            objectName: "processGroup:" + modelData.id
            Layout.fillWidth: true
            spacing: 4

            RowLayout {
                visible: group.modelData.label.length > 0
                spacing: 8

                ShellButton {
                    objectName: "fold"
                    subtle: true
                    text: group.modelData.collapsed ? qsTr("Show") : qsTr("Hide")
                    Accessible.name: group.modelData.collapsed ? qsTr("Show %1 processes").arg(group.modelData.label) : qsTr("Hide %1 processes").arg(group.modelData.label)
                    onClicked: Shell.dispatch("diagnostics.group", { id: group.modelData.id })
                }

                Label {
                    objectName: "label"
                    text: qsTr("%1 (%2)").arg(group.modelData.label).arg(group.modelData.count)
                    color: diagnostics.foreground
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    font.weight: Font.DemiBold
                }
            }

            Repeater {
                model: group.modelData.collapsed ? [] : group.modelData.rows

                RowLayout {
                    id: process

                    required property var modelData

                    objectName: "process:" + modelData.pid
                    Layout.fillWidth: true
                    spacing: 12

                    Label {
                        Layout.fillWidth: true
                        Layout.leftMargin: 12 * process.modelData.depth
                        text: process.modelData.name
                        elide: Text.ElideRight
                        color: diagnostics.foreground
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        ToolTip.visible: hover.hovered
                        ToolTip.text: process.modelData.command

                        HoverHandler {
                            id: hover
                        }
                    }

                    Repeater {
                        model: [process.modelData.cpu, process.modelData.memory, String(process.modelData.pid), process.modelData.type]

                        Label {
                            required property var modelData
                            Layout.preferredWidth: 80
                            text: modelData
                            color: diagnostics.foreground
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                        }
                    }

                    ShellButton {
                        objectName: "sigint"
                        subtle: true
                        text: "INT"
                        enabled: !process.modelData.signaling
                        Accessible.name: qsTr("Send SIGINT")
                        ToolTip.visible: hovered
                        ToolTip.text: qsTr("Send SIGINT")
                        onClicked: Shell.dispatch("diagnostics.signal", { pid: process.modelData.pid, signal: "SIGINT" })
                    }

                    ShellButton {
                        objectName: "sigkill"
                        subtle: true
                        text: "KILL"
                        tint: diagnostics.danger
                        enabled: !process.modelData.signaling
                        Accessible.name: qsTr("Send SIGKILL")
                        ToolTip.visible: hovered
                        ToolTip.text: qsTr("Send SIGKILL")
                        onClicked: Shell.dispatch("diagnostics.signal", { pid: process.modelData.pid, signal: "SIGKILL" })
                    }
                }
            }
        }
    }

    Heading {
        text: qsTr("Resource History")

        Repeater {
            model: diagnostics.history.windows ?? []

            ShellButton {
                required property var modelData
                objectName: "window:" + modelData.label
                subtle: diagnostics.history.windowMs !== modelData.windowMs
                text: modelData.label
                onClicked: Shell.dispatch("diagnostics.window", { windowMs: modelData.windowMs })
            }
        }
    }

    Stats {
        figures: [[qsTr("CPU Time"), diagnostics.history.cpuTime ?? "..."], [qsTr("Samples"), diagnostics.history.samples ?? "..."],
                  [qsTr("Interval"), diagnostics.history.interval ?? "..."], [qsTr("Processes"), diagnostics.history.count ?? "..."]]
    }

    Failure {
        message: diagnostics.history.error ?? ""
    }

    Cells {
        header: true
        cells: [qsTr("Name"), qsTr("Avg CPU"), qsTr("Peak CPU"), qsTr("Peak Memory"), qsTr("CPU Time")]
    }

    Repeater {
        model: diagnostics.history.rows ?? []

        Cells {
            required property var modelData
            objectName: "historyRow:" + modelData.pid
            cells: [modelData.name, modelData.avgCpu, modelData.maxCpu, modelData.maxMemory, modelData.cpuTime]
        }
    }

    Heading {
        text: qsTr("Trace Diagnostics")

        ShellButton {
            objectName: "openLogs"
            visible: diagnostics.settings?.logs?.available ?? false
            text: qsTr("Open logs folder")
            iconName: "folder-open"
            onClicked: Shell.dispatch("diagnostics.openLogs")
        }
    }

    Failure {
        objectName: "logsError"
        message: diagnostics.settings?.logs?.error ?? ""
    }

    Stats {
        figures: [[qsTr("Spans"), diagnostics.traces.spans ?? "..."], [qsTr("Failures"), diagnostics.traces.failures ?? "..."],
                  [qsTr("Slow Spans"), diagnostics.traces.slowSpans ?? "..."], [qsTr("Parse Errors"), diagnostics.traces.parseErrors ?? "..."]]
    }

    Failure {
        objectName: "tracesError"
        message: diagnostics.traces.error ?? ""
    }

    Heading {
        visible: (diagnostics.traces.latestFailures ?? []).length > 0
        text: qsTr("Latest Failures")
    }

    Repeater {
        model: diagnostics.traces.latestFailures ?? []

        Cells {
            required property var modelData
            cells: [modelData.name + " · " + modelData.cause, modelData.duration]
        }
    }

    Heading {
        visible: (diagnostics.traces.commonFailures ?? []).length > 0
        text: qsTr("Most Common Failures")
    }

    Repeater {
        model: diagnostics.traces.commonFailures ?? []

        Cells {
            required property var modelData
            cells: [modelData.name + " · " + modelData.cause, modelData.count]
        }
    }

    Heading {
        visible: (diagnostics.traces.slowestSpans ?? []).length > 0
        text: qsTr("Slowest Spans")
    }

    Repeater {
        model: diagnostics.traces.slowestSpans ?? []

        Cells {
            required property var modelData
            cells: [modelData.name, modelData.duration]
        }
    }
}
