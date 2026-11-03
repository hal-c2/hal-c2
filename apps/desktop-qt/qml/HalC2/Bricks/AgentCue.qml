import QtQuick
import HalC2.Shell

// What an agent does in a browser tab, over its page: a badge while it acts,
// its pointer where it last acted (dimmer when idle, dimmer still while the
// user is in control), and one ripple where it clicks. `entry` is the tab's
// PreviewAutomation.activity; `pageScale` maps the page's CSS pixels onto
// this item, whose origin is the page's.
//
//   AgentCue { x: webView.x; y: webView.y; entry: PreviewAutomation.activity[tabId]; pageScale: zoom * webView.scale }
Item {
    id: root

    property var entry: null
    property real pageScale: 1
    property bool reduceMotion: false

    readonly property bool acting: !!entry && !!entry.label
    readonly property var pointer: entry && entry.pointer ? entry.pointer : null
    readonly property color accent: Theme.palette.color("accent", "#3b82f6")

    objectName: "agentCue"

    // Rings once at a click's point: one short animation, none with reduced motion.
    onPointerChanged: {
        if (!pointer || reduceMotion || !entry || entry.operation !== "click")
            return;
        ripple.x = pointer.x * pageScale - ripple.width / 2;
        ripple.y = pointer.y * pageScale - ripple.height / 2;
        rippling.restart();
    }

    Rectangle {
        objectName: "agentCueBadge"
        visible: root.acting
        anchors.horizontalCenter: parent.horizontalCenter
        y: 8
        width: badgeText.implicitWidth + 20
        height: badgeText.implicitHeight + 8
        radius: height / 2
        color: Theme.palette.color("surfaceRaised", "#1f1f23")
        border.color: root.accent
        opacity: 0.92

        Text {
            id: badgeText

            anchors.centerIn: parent
            text: root.entry && root.entry.label ? root.entry.label : ""
            color: Theme.palette.color("text", "#e4e4e7")
            font.pixelSize: 11 * Theme.fontScale
        }
    }

    Rectangle {
        objectName: "agentCuePointer"
        visible: root.pointer !== null
        width: 14
        height: 14
        radius: 7
        x: root.pointer ? root.pointer.x * root.pageScale - width / 2 : 0
        y: root.pointer ? root.pointer.y * root.pageScale - height / 2 : 0
        color: root.accent
        border.color: "white"
        border.width: 2
        opacity: !root.entry ? 0 : root.entry.userInControl ? 0.25 : root.acting ? 0.95 : 0.5

        Behavior on x {
            enabled: !root.reduceMotion
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }
        Behavior on y {
            enabled: !root.reduceMotion
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
        }
        Behavior on opacity {
            enabled: !root.reduceMotion
            NumberAnimation { duration: 250 }
        }
    }

    Rectangle {
        id: ripple

        objectName: "agentCueRipple"
        width: 36
        height: 36
        radius: 18
        color: "transparent"
        border.color: root.accent
        border.width: 2
        opacity: 0

        ParallelAnimation {
            id: rippling

            NumberAnimation { target: ripple; property: "scale"; from: 0.3; to: 1.4; duration: 400; easing.type: Easing.OutCubic }
            NumberAnimation { target: ripple; property: "opacity"; from: 0.7; to: 0; duration: 400 }
        }
    }
}
