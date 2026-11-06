pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// What "/usage-limits" answers with, on the composer's top edge
// (`composer.usageLimits`): the rate-limit windows of each account the current
// provider's driver has, here and through hubs, as the environment last
// reported them, until dismissed or the next message. An account named by its
// email is scrambled until clicked.
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
        // Read again each minute too, so "tomorrow" turns to today at midnight.
        const at = Format.at(iso);
        Format.follow();
        Format.minute;
        return at ? qsTr("resets %1").arg(Threads.upcoming(at)) : "";
    }

    // An account's hub, name and plan; a name that is an email is scrambled
    // until clicked, the hub it came through still named.
    component Account: RowLayout {
        id: named

        property var account: null
        readonly property bool sensitive: !!account && account.sensitive === true
        readonly property string source: account ? account.source ?? "" : ""
        readonly property string plan: account ? account.plan ?? "" : ""

        spacing: 0

        Label {
            visible: !named.sensitive
            Layout.fillWidth: !named.sensitive
            text: named.account ? (named.source.length > 0 ? named.source + " · " : "") + named.account.label + (named.plan.length > 0 ? " · " + named.plan : "") : ""
            elide: Text.ElideRight
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Theme.type.meta.size
        }

        Label {
            visible: named.sensitive && named.source.length > 0
            // The hub gives way (with the plan), so a long name leaves room for the account.
            Layout.fillWidth: true
            Layout.maximumWidth: implicitWidth
            text: named.source + " · "
            elide: Text.ElideRight
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Theme.type.meta.size
        }

        RedactedText {
            objectName: "composerUsageLimitsAccount"
            visible: named.sensitive
            value: named.sensitive ? named.account.label : ""
            Accessible.name: qsTr("Toggle account label visibility")
            revealTip: qsTr("Click to reveal account")
            hideTip: qsTr("Click to hide account")
        }

        Label {
            visible: named.sensitive
            Layout.fillWidth: named.sensitive
            text: named.plan.length > 0 ? " · " + named.plan : ""
            elide: Text.ElideRight
            color: Theme.palette.color("textMuted", "#a1a1aa")
            font.pixelSize: Theme.type.meta.size
        }
    }

    ColumnLayout {
        id: column

        anchors.fill: parent
        anchors.margins: 8
        spacing: 4

        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Label {
                text: qsTr("Usage limits")
                color: Theme.palette.color("text", "#e4e4e7")
                font.pixelSize: Theme.type.body.size
                font.weight: Font.DemiBold
            }

            // Whose limits: the one account, or how many.
            Account {
                Layout.fillWidth: true
                account: card.limits ? card.limits.summary : null
            }

            ShellButton {
                objectName: "composerUsageLimitsDismiss"
                subtle: true
                iconName: "x"
                Accessible.name: qsTr("Dismiss usage limits")
                onClicked: Shell.dispatch("composer.usageLimits.dismiss")
            }
        }

        Repeater {
            model: card.limits ? card.limits.accounts : []

            delegate: ColumnLayout {
                id: entry

                required property var modelData

                Layout.fillWidth: true
                spacing: 2

                // Each is named once there are several.
                Account {
                    Layout.fillWidth: true
                    visible: card.limits.accounts.length > 1
                    account: entry.modelData
                }

                Label {
                    Layout.fillWidth: true
                    visible: text.length > 0
                    text: entry.modelData.notice
                    color: Theme.palette.color("textMuted", "#a1a1aa")
                    font.pixelSize: Theme.type.meta.size
                    wrapMode: Text.Wrap
                }

                Repeater {
                    model: entry.modelData.windows

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

        Repeater {
            model: card.limits ? card.limits.notices : []

            delegate: Label {
                required property string modelData

                Layout.fillWidth: true
                text: modelData
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Theme.type.meta.size
                wrapMode: Text.Wrap
            }
        }
    }
}
