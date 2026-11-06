pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// What "/usage-limits" answers with, on the composer's top edge
// (`composer.usageLimits`): the current provider's rate-limit windows as the
// environment last reported them, until dismissed or the next message.
Rectangle {
    id: card

    readonly property var limits: Shell.state.composer ? Shell.state.composer.usageLimits ?? null : null

    objectName: "composerUsageLimits"
    visible: limits !== null
    implicitHeight: visible ? column.implicitHeight + 16 : 0
    radius: Theme.radiusMd
    color: Theme.palette.color("surfaceOverlay", "#18181b")
    border.color: Theme.palette.color("border", "#27272a")
    border.width: 1

    function resets(iso) {
        // As the timeline says when a limit resets: "18:05", "tomorrow at 18:05".
        const at = Format.at(iso);
        Format.follow();
        return at ? qsTr("resets %1").arg(Threads.upcoming(at)) : "";
    }

    ColumnLayout {
        id: column

        anchors.fill: parent
        anchors.margins: 8
        spacing: 4

        RowLayout {
            Layout.fillWidth: true

            Label {
                Layout.fillWidth: true
                text: card.limits ? qsTr("%1 limits").arg(card.limits.provider) : ""
                elide: Text.ElideRight
                color: Theme.palette.color("text", "#e4e4e7")
                font.pixelSize: Theme.type.body.size
                font.weight: Font.DemiBold
            }

            ShellButton {
                objectName: "composerUsageLimitsDismiss"
                subtle: true
                iconName: "x"
                Accessible.name: qsTr("Dismiss limits")
                onClicked: Shell.dispatch("composer.usageLimits.dismiss")
            }
        }

        Label {
            Layout.fillWidth: true
            visible: text.length > 0
            text: card.limits ? card.limits.message : ""
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Theme.type.meta.size
            wrapMode: Text.Wrap
        }

        Repeater {
            model: card.limits ? card.limits.windows : []

            delegate: RowLayout {
                id: row

                required property var modelData

                Layout.fillWidth: true
                spacing: 8

                Label {
                    Layout.fillWidth: true
                    text: row.modelData.label
                    elide: Text.ElideRight
                    color: Theme.palette.color("text", "#e4e4e7")
                    font.pixelSize: Theme.type.meta.size
                }

                Label {
                    text: qsTr("%1% left").arg(Math.round(row.modelData.remainingPercent))
                    color: Theme.palette.color("text", "#e4e4e7")
                    font.pixelSize: Theme.type.meta.size
                }

                Label {
                    text: card.resets(row.modelData.resetsAt)
                    color: Theme.palette.color("textMuted", "#a1a1aa")
                    font.pixelSize: Theme.type.meta.size
                }
            }
        }
    }
}
