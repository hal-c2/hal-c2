import QtQuick
import QtQuick.Layouts
import HalC2.Shell

// What the open page says about the agent asked to work on it, with the way to
// its thread, to stop it, to restore an earlier version and to clear what is said.
// Shared by the desktop's page and the phone's, which asks for taller buttons.
Rectangle {
    id: strip

    property int buttonHeight: 28
    readonly property string status: Spaces.agent.status ?? ""
    // The MC takes no second ask until this one ends.
    readonly property bool active: status === "running" || status === "stopping"
    readonly property bool failed: status === "failed"
    readonly property color tone: Theme.palette.color(failed ? "error" : "accent", failed ? "#ef4444" : "#2563eb")

    // The error as a sentence's middle: a provider's own text may end its sentence already.
    readonly property string error: (Spaces.agent.error ?? "").replace(/[.\s]+$/, "")

    signal historyRequested

    objectName: "spaceAgentStrip"
    visible: status !== ""
    implicitHeight: content.implicitHeight + 16
    radius: Math.min(Theme.radius, 8)
    color: Qt.alpha(tone, 0.12)
    border.color: Qt.alpha(tone, 0.4)

    ColumnLayout {
        id: content

        anchors.fill: parent
        anchors.margins: 8
        spacing: 6

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            ShellIcon {
                Layout.alignment: Qt.AlignTop
                name: "sparkles"
                size: 14
                color: Theme.palette.color("text", "#e4e4e7")
            }

            Text {
                objectName: "spaceAgentText"
                // The request and the provider's error are shown as they came, not as markup.
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: {
                    switch (strip.status) {
                    case "running":
                        return qsTr("An agent is working on “%1”.").arg(Spaces.agent.request ?? "");
                    case "stopping":
                        return qsTr("Stopping the agent…");
                    case "completed":
                        return Spaces.agent.edited ? qsTr("The agent finished and changed this page.") : qsTr("The agent finished without changing this page.");
                    case "failed":
                        return qsTr("The agent failed: %1. The page stays as it last wrote it.").arg(strip.error);
                    case "stopped":
                        return strip.error ? qsTr("The agent stopped: %1.").arg(strip.error) : qsTr("The agent was stopped.");
                    }
                    return "";
                }
                color: Theme.palette.color("text", "#e4e4e7")
                wrapMode: Text.Wrap
                font.pixelSize: Math.round(13 * Theme.fontScale)
            }
        }

        Flow {
            Layout.fillWidth: true
            spacing: 6

            ShellButton {
                objectName: "spaceAgentOpenThread"
                implicitHeight: strip.buttonHeight
                text: qsTr("Open thread")
                iconName: "message-square"
                onClicked: Shell.dispatch("space.agent.openThread", {})
            }

            ShellButton {
                objectName: "spaceAgentStop"
                implicitHeight: strip.buttonHeight
                // Also while stopping: a provider can ignore the first stop.
                visible: strip.active
                text: qsTr("Stop")
                iconName: "square"
                onClicked: Shell.dispatch("space.agent.stop", { pageId: Spaces.pageId })
            }

            ShellButton {
                objectName: "spaceAgentHistory"
                implicitHeight: strip.buttonHeight
                visible: !strip.active
                text: qsTr("History")
                iconName: "clock"
                onClicked: strip.historyRequested()
            }

            ShellButton {
                objectName: "spaceAgentDismiss"
                implicitHeight: strip.buttonHeight
                visible: !strip.active
                text: qsTr("Dismiss")
                iconName: "x"
                onClicked: Shell.dispatch("space.agent.dismiss", { pageId: Spaces.pageId })
            }
        }
    }
}
