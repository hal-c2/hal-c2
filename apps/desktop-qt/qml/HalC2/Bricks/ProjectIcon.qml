import QtQuick
import HalC2.Shell

// A project's icon as `projectIcons` describes it (IdentityController): a
// monogram tile, an emoji, a symbol in its colour, or an image the MC serves.
//
//   ProjectIcon { icon: Shell.state.projectIcons?.[projectKey] ?? null }
Item {
    id: root

    property var icon: null
    property real size: 16
    readonly property string kind: icon?.kind ?? ""
    readonly property color tint: icon?.tint ?? Theme.palette.color("textMuted", "#8b8b93")

    implicitWidth: size
    implicitHeight: size
    visible: kind.length > 0
    Accessible.ignored: true

    Rectangle {
        objectName: "projectIconMonogram"
        anchors.fill: parent
        visible: root.kind === "monogram"
        radius: root.size / 4
        color: Qt.alpha(root.tint, 0.14)

        Text {
            anchors.centerIn: parent
            text: root.icon?.text ?? ""
            color: root.tint
            font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
            font.pixelSize: Math.round(root.size * 0.5)
            font.weight: Font.Bold
        }
    }
    Text {
        objectName: "projectIconEmoji"
        anchors.centerIn: parent
        visible: root.kind === "emoji"
        text: root.icon?.emoji ?? ""
        font.pixelSize: Math.round(root.size * 0.8)
    }
    ShellIcon {
        objectName: "projectIconSymbol"
        anchors.centerIn: parent
        visible: root.kind === "lucide"
        name: root.icon?.name ?? ""
        size: root.size * 0.875
        color: root.tint
    }
    Image {
        objectName: "projectIconImage"
        anchors.fill: parent
        visible: root.kind === "image" && status === Image.Ready
        source: root.kind === "image" ? root.icon.url : ""
        sourceSize: Qt.size(root.size * 2, root.size * 2)
        fillMode: Image.PreserveAspectFit
        asynchronous: true
    }
}
