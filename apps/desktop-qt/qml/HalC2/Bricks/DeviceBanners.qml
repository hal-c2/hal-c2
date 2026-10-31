pragma ComponentBehavior: Bound
import QtQuick
import HalC2.Shell

// One banner per machine whose device tools are installing, starting or
// failed (ThreadDevices' view.banners), shared by the Device tab and its
// setup wizard so both say the same thing. A failed machine offers Retry
// when the MC can retry one machine.
Column {
    id: root

    property var source: null
    // One banners row per surface (the tab's list, its setup pointer, the
    // wizard); their test names are told apart by this prefix.
    property string namePrefix: "deviceBanner"

    readonly property var banners: source && source.view ? source.view.banners : []
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color borderColor: Theme.palette.color("border", "#27272a")

    objectName: "deviceBanners"
    spacing: 6

    Repeater {
        model: root.banners

        delegate: Rectangle {
            id: banner

            required property var modelData

            objectName: root.namePrefix + "-" + modelData.hostId
            width: root.width
            height: bannerColumn.implicitHeight + 16
            radius: 6
            color: "transparent"
            border.color: root.borderColor

            Column {
                id: bannerColumn

                x: 12
                y: 8
                width: parent.width - (retryButton.visible ? 96 : 24)
                spacing: 2

                Text {
                    text: banner.modelData.label
                    color: root.foreground
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    font.weight: Font.Medium
                }
                Text {
                    objectName: root.namePrefix + "Message-" + banner.modelData.hostId
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: banner.modelData.message
                    color: root.muted
                    font.pixelSize: Math.round(11 * Theme.fontScale)
                }
                Text {
                    width: parent.width
                    visible: banner.modelData.advice.length > 0
                    wrapMode: Text.Wrap
                    text: banner.modelData.advice
                    color: root.muted
                    font.pixelSize: Math.round(11 * Theme.fontScale)
                }
            }
            ShellButton {
                id: retryButton

                objectName: root.namePrefix + "Retry-" + banner.modelData.hostId
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.top: parent.top
                anchors.topMargin: 8
                visible: banner.modelData.canRetry
                text: banner.modelData.retrying ? qsTr("Retrying…") : qsTr("Retry")
                enabled: !banner.modelData.retrying
                onClicked: root.source.retryHost(banner.modelData.hostId)
            }
        }
    }
}
