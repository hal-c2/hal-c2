import QtQuick
import HalC2.Shell

// The build's stage as a pill, "Dev" or "Nightly" (StageController's label).
// The Sidebar draws it by its wordmark; a shell with a wordmark of its own
// sets `visible` to when it marks the stage.
Rectangle {
    id: pill

    readonly property var stage: Shell.state.stage ?? null

    implicitWidth: pillText.implicitWidth + 12
    implicitHeight: 18
    radius: 9
    color: Theme.palette.color("secondary", "#27272a")
    border.width: 1
    border.color: Theme.palette.color("border", "#3f3f46")

    Text {
        id: pillText

        anchors.centerIn: parent
        text: pill.stage !== null ? (pill.stage.label ?? "") : ""
        color: Theme.palette.color("secondaryForeground", "#e4e4e7")
        font.pixelSize: Math.round(10 * Theme.fontScale)
        font.weight: Font.DemiBold
    }
}
