import QtQuick
import HalC2.Shell

// A project's icon as `projectIcons` describes it (IdentityController): a
// monogram tile, an emoji, a symbol in its colour, or an image the MC serves.
// A project with no icon yet draws its name's first letter in a neutral tile
// when given `name`, and nothing without it. An image that has not loaded
// (yet, or at all) shows the project's monogram in its colour until it does.
//
//   ProjectIcon { icon: Shell.state.projectIcons?.[projectKey] ?? null; name: projectName }
Item {
    id: root

    property var icon: null
    property string name: ""
    property real size: 16
    readonly property string fallbackText: name.trim().charAt(0).toUpperCase()
    readonly property string kind: icon?.kind ?? (fallbackText.length > 0 ? "monogram" : "")
    readonly property color tint: icon?.tint ?? Theme.palette.color("inkTertiary", "#8b919e")

    implicitWidth: size
    implicitHeight: size
    visible: kind.length > 0
    Accessible.ignored: true

    Rectangle {
        objectName: "projectIconMonogram"
        anchors.fill: parent
        visible: root.kind === "monogram" || (root.kind === "image" && image.status !== Image.Ready && root.fallbackText.length > 0)
        radius: Theme.radiusXs
        // The raised surface in the project's colour, so the colour carries
        // at the sidebar's 14px.
        color: Qt.tint(Theme.palette.color("surfaceRaised", "#1c1f26"), Qt.alpha(root.tint, 0.22))

        Text {
            objectName: "projectIconMonogramText"
            anchors.centerIn: parent
            text: root.icon?.text ?? root.fallbackText
            color: root.tint
            font.family: Theme.fontMono.length > 0 ? Theme.fontMono : "monospace"
            // Large enough to read on the sidebar's 14px mark; two letters still fit.
            font.pixelSize: Math.round(root.size * 0.64)
            font.weight: Font.DemiBold
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
        id: image
        objectName: "projectIconImage"
        anchors.fill: parent
        visible: root.kind === "image" && status === Image.Ready
        source: root.kind === "image" ? root.icon.url : ""
        sourceSize: Qt.size(root.size * 2, root.size * 2)
        fillMode: Image.PreserveAspectFit
        asynchronous: true
    }
}
