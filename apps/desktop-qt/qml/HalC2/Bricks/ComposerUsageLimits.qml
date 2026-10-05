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
    radius: Math.min(Theme.radius, 8)
    color: Theme.palette.color("surfaceOverlay", "#18181b")
    border.color: Theme.palette.color("border", "#27272a")
    border.width: 1

    function resets(iso) {
        const date = new Date(iso);
        return isNaN(date.getTime()) ? "" : qsTr("resets %1").arg(date.toLocaleString(Qt.locale(), Locale.ShortFormat));
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
                color: Theme.palette.color("text", "#e4e4e7")
                font.pixelSize: Math.round(13 * Theme.fontScale)
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
            font.pixelSize: Math.round(12 * Theme.fontScale)
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
                    color: Theme.palette.color("text", "#e4e4e7")
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }

                Label {
                    text: qsTr("%1% left").arg(Math.round(row.modelData.remainingPercent))
                    color: Theme.palette.color("text", "#e4e4e7")
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }

                Label {
                    text: card.resets(row.modelData.resetsAt)
                    color: Theme.palette.color("textMuted", "#a1a1aa")
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }
            }
        }
    }
}
