import QtQuick
import QtQuick.Controls.Basic
import HalC2.Shell

// Something sensitive, such as an account's email, scrambled until the user
// clicks it and scrambled again on the next click. The scramble keeps the
// length and separators, the rest drawn from a hash of the value, so two
// accounts can be told apart without being read.
Button {
    id: root

    required property string value
    property bool revealed: false
    property string revealTip: qsTr("Show account")
    property string hideTip: qsTr("Hide account")
    property color color: Theme.palette.color("inkTertiary", "#a1a1aa")
    property color hoverColor: Theme.palette.color("ink", "#e4e4e7")

    function redacted(value) {
        const alphabet = "abcdefghjkmnpqrstuvwxyz23456789";
        let state = 0x811c9dc5 | 0;
        for (let i = 0; i < value.length; ++i) {
            state ^= value.charCodeAt(i);
            state = Math.imul(state, 0x01000193);
        }
        let result = "";
        for (const ch of value) {
            if (ch === "@" || ch === "." || ch === "-" || ch === "_") {
                result += ch;
                continue;
            }
            state = Math.imul(state ^ (state >>> 13), 0x85ebca6b);
            state = Math.imul(state ^ (state >>> 16), 0xc2b2ae35);
            result += alphabet[Math.abs(state) % alphabet.length];
        }
        return result;
    }

    flat: true
    padding: 0
    // Tall enough to hit, though the text is small.
    implicitHeight: Math.max(24, implicitContentHeight)
    text: revealed ? value : redacted(value)
    font.pixelSize: Theme.type.caption.size
    font.family: "monospace"
    ToolTip.visible: hovered
    ToolTip.text: revealed ? hideTip : revealTip
    onClicked: revealed = !revealed

    contentItem: Label {
        text: root.text
        elide: Text.ElideRight
        verticalAlignment: Text.AlignVCenter
        color: root.hovered ? root.hoverColor : root.color
        font: root.font
    }
    background: Rectangle {
        color: "transparent"
        radius: Theme.radiusXs
        border.width: root.visualFocus ? 1 : 0
        border.color: Theme.palette.color("focus", "#3b82f6")
    }
}
