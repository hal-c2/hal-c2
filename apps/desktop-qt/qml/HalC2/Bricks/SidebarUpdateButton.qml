pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The sidebar footer's update button (DesktopUpdateController's
// `desktopUpdate`): its tooltip says where the desktop app's update stands
// and a click does the next step, downloading or restarting to install. A
// nightly update's release notes open beside it while it is hovered.
ShellButton {
    id: button

    readonly property var update: Shell.state.desktopUpdate ?? null
    readonly property var notes: update?.popover ?? null
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")

    objectName: "sidebarUpdateButton"
    visible: update !== null && update.shown === true
    enabled: update !== null && update.disabled !== true
    subtle: true
    implicitHeight: 32
    iconSize: 16
    iconName: update?.action === "install" ? "rotate-ccw" : update?.action === "download" ? "download" : "refresh-cw"
    Accessible.name: update?.label ?? qsTr("Check for updates")
    toolTip: notes === null ? (update?.label ?? "") : ""
    onClicked: Shell.dispatch("desktopUpdate.press")
    onHoveredChanged: {
        if (hovered && notes !== null) releaseNotes.open();
    }

    Popup {
        id: releaseNotes

        objectName: "sidebarUpdateReleaseNotes"
        x: button.width + 8
        y: button.height - height
        width: 320
        padding: 12
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            color: Theme.palette.color("surfaceOverlay", "#18181b")
            border.color: Qt.alpha(button.foreground, 0.1)
            radius: 10
        }

        contentItem: ColumnLayout {
            spacing: 8

            Label {
                Layout.fillWidth: true
                text: button.update?.label ?? ""
                color: button.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
                font.weight: Font.Medium
                wrapMode: Text.Wrap
            }

            Repeater {
                model: button.notes?.groups ?? []

                ColumnLayout {
                    id: group

                    required property var modelData

                    Layout.fillWidth: true
                    spacing: 4

                    Label {
                        text: group.modelData.title
                        color: button.muted
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        font.weight: Font.DemiBold
                    }

                    Repeater {
                        model: group.modelData.items

                        Label {
                            required property string modelData

                            Layout.fillWidth: true
                            text: "• " + modelData
                            color: button.foreground
                            font.pixelSize: Math.round(12 * Theme.fontScale)
                            wrapMode: Text.Wrap
                        }
                    }

                    ShellButton {
                        subtle: true
                        text: group.modelData.link
                        onClicked: Shell.dispatch("desktopUpdate.openReleaseNotes", {
                            url: group.modelData.url
                        })
                    }
                }
            }

            ShellButton {
                visible: (button.notes?.footer ?? "").length > 0
                subtle: true
                text: button.notes?.footer ?? ""
                onClicked: Shell.dispatch("desktopUpdate.openReleaseNotes", {
                    url: button.notes.footerUrl
                })
            }
        }
    }
}
